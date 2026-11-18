import Foundation

/// What the runtime needs at launch: the metered module the catalog wrote, and the manifest its
/// permissions come from. Immutable, so every lane can share one.
struct PluginModule: Sendable, Hashable {
    let manifest: PluginManifest
    let meteredURL: URL
}

/// One plugin command, running in a WebAssembly instance of its own on a queue of its own: the
/// same lanes, renderer and host APIs a Raycast command has, reached only through calls
/// `PluginHostPolicy` lets through. Nothing is shared between plugins or kept between launches.
final class WasmPluginRuntime: @unchecked Sendable {
    private let module: PluginModule
    private let hostAPI: ExtensionHostAPI
    private let appScheme: String
    private let callBudget: Duration
    private let queue: DispatchQueue
    /// Set once before launch, read on the queue.
    private nonisolated(unsafe) weak var delegate: ExtensionRuntimeDelegate?

    // Everything below is the queue's.
    private var instance: WasmInstance?
    private var session: String?
    private var output = ""
    private var timers: [UInt32: DispatchSourceTimer] = [:]
    private var hostTasks: [UInt32: Task<Void, Never>] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var generation = UUID()

    /// The one session a runtime runs, as the kit numbers it.
    private static let sessionNumber: UInt32 = 1
    /// What's kept of what the plugin printed, for the error report.
    private static let outputLimit = 16 * 1024

    /// `callBudget` is how long one call into the plugin may run before it is stopped.
    init(
        module: PluginModule, hostAPI: ExtensionHostAPI, appScheme: String, priority: DispatchQoS,
        callBudget: Duration = .seconds(5)
    ) {
        self.module = module
        self.callBudget = callBudget
        self.hostAPI = hostAPI
        self.appScheme = appScheme
        queue = DispatchQueue(label: "com.tinycast.plugins.wasm", qos: priority, autoreleaseFrequency: .workItem)
    }

    // MARK: - Launching

    private func payload(for context: ExtensionLaunchContext) async -> String {
        // `@AppStorage` reads synchronously, so the launch brings the plugin's storage with it.
        let stored = (try? await hostAPI.perform(api: "storage", method: "all", arguments: [])) ?? "{}"
        var fields = Self.object(context.jsonString())
        fields["localStorage"] = Self.object(stored)
        fields["appScheme"] = appScheme
        return ExtensionJSON.string(from: fields)
    }

    private func start(session: String, command: String, payload: String) throws(PluginLaunchError) {
        if instance == nil {
            guard let metered = try? Data(contentsOf: module.meteredURL, options: .alwaysMapped) else {
                throw PluginLaunchError(message: String(localized: "The plugin's module is gone; reload plugins."))
            }
            do {
                instance = try WasmInstance(module: metered, imports: imports(), budget: callBudget)
            } catch {
                throw PluginLaunchError(message: error.description + reportedOutput())
            }
        }
        self.session = session
        guarded { try $0.call("tinycast_launch", [.number(Self.sessionNumber), .text(command), .text(payload)]) }
    }

    /// Runs one call into the plugin; a trap, an exit or a missed deadline ends the instance,
    /// whose Swift state can't be trusted after it, and fails the session.
    private func guarded(_ body: (WasmInstance) throws -> Void) {
        guard let instance else { return }
        do {
            try body(instance)
        } catch {
            tearDown()
            let message = (error as? WasmInstance.Failure)?.description ?? String(describing: error)
            report(failure: message + reportedOutput())
        }
    }

    private func reportedOutput() -> String {
        let printed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return printed.isEmpty ? "" : "\n\n" + printed
    }

    // MARK: - The imports

    private func imports() -> WasmInstance.Imports {
        var imports = WasmInstance.Imports()
        imports.render = { [weak self] _, json in self?.deliverRender(json) }
        imports.navigation = { [weak self] _, depth in
            guard let self, let session, let delegate else { return }
            Task { @MainActor in delegate.runtime(self, session: session, navigationDepth: Int(depth)) }
        }
        imports.finished = { [weak self] _ in
            guard let self, let session, let delegate else { return }
            Task { @MainActor in delegate.runtime(self, session: session, didFinish: ()) }
        }
        imports.failed = { [weak self] _, message in
            guard let self else { return }
            self.report(failure: message + self.reportedOutput())
        }
        imports.call = { [weak self] id, request in self?.perform(id: id, request: request) }
        imports.setTimer = { [weak self] token, milliseconds in self?.startTimer(token, milliseconds) }
        imports.clearTimer = { [weak self] token in
            self?.timers.removeValue(forKey: token)?.cancel()
        }
        imports.output = { [weak self] text in
            guard let self, self.output.utf8.count < Self.outputLimit else { return }
            self.output += text
        }
        return imports
    }

    private func deliverRender(_ json: String) {
        guard let session, let delegate else { return }
        // Parsing a large list is the expensive part, and it belongs off the main actor.
        guard let tree = RenderTree(json: json) else {
            return report(failure: "The plugin rendered something Tinycast can't read.")
        }
        Task { @MainActor in delegate.runtime(self, session: session, didRender: tree) }
    }

    private func report(failure message: String) {
        guard let session, let delegate else { return }
        self.session = nil
        Task { @MainActor in delegate.runtime(self, session: session, didFail: message) }
    }

    /// The plugin waits for the answer through `tinycast_settle`, which always comes on a later
    /// turn of the queue, never inside the call that asked.
    private func perform(id: UInt32, request: String) {
        let fields = Self.object(request)
        let api = fields["api"] as? String ?? ""
        let method = fields["method"] as? String ?? ""
        let arguments = (fields["args"] as? [Any] ?? []).map(RenderValue.init(json:))
        if let refusal = PluginHostPolicy.refusal(
            api: api, method: method, arguments: arguments, manifest: module.manifest)
        {
            let generation = generation
            queue.async { self.settle(id: id, generation: generation, ok: false, answer: refusal) }
            return
        }
        let hostAPI = hostAPI
        let generation = generation
        hostTasks[id] = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let ok: Bool
            let answer: String
            do {
                answer = try await hostAPI.perform(api: api, method: method, arguments: arguments)
                ok = true
            } catch {
                answer = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                ok = false
            }
            guard let self else { return }
            self.queue.async { self.settle(id: id, generation: generation, ok: ok, answer: answer) }
        }
    }

    private func settle(id: UInt32, generation: UUID, ok: Bool, answer: String) {
        guard generation == self.generation else { return }
        hostTasks[id] = nil
        guarded { try $0.call("tinycast_settle", [.number(id), .number(ok ? 1.0 : 0.0), .text(answer)]) }
        if hostTasks.isEmpty { resumeIdleWaiters() }
    }

    private func startTimer(_ token: UInt32, _ milliseconds: Double) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(milliseconds, 0) / 1000)
        timer.setEventHandler { [weak self] in
            guard let self, self.timers.removeValue(forKey: token) != nil else { return }
            self.guarded { try $0.call("tinycast_timer", [.number(token)]) }
        }
        timers[token]?.cancel()
        timers[token] = timer
        timer.resume()
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func tearDown() {
        for timer in timers.values { timer.cancel() }
        timers = [:]
        for task in hostTasks.values { task.cancel() }
        hostTasks = [:]
        resumeIdleWaiters()
        generation = UUID()
        instance = nil
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    private static func object(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

/// Why a plugin's command didn't start, with what the plugin printed.
struct PluginLaunchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension WasmPluginRuntime: ExtensionCommandRuntime {
    func setDelegate(_ delegate: ExtensionRuntimeDelegate) {
        self.delegate = delegate
    }

    /// The instance starts with the first launch, which compiles the module.
    func boot(config: ExtensionBootConfig) async throws {}

    func launch(
        session: String, owner: InstalledExtension, command: ExtensionCommand, context: ExtensionLaunchContext
    ) async throws {
        guard module.manifest.commands.contains(where: { $0.name == command.name }) else {
            throw ExtensionLaunchError.unknownCommand(command.name)
        }
        let payload = await payload(for: context)
        let name = command.name
        let result: Result<Void, PluginLaunchError> = await onQueue {
            Result { () throws(PluginLaunchError) in
                try self.start(session: session, command: name, payload: payload)
            }
        }
        try result.get()
    }

    func dispatch(session: String, handler: String, payload: String, completesSession: Bool) async {
        await onQueue {
            guard session == self.session else { return }
            self.guarded {
                try $0.call(
                    "tinycast_dispatch", [.text(handler), .text(payload), .number(completesSession ? 1.0 : 0.0)])
            }
        }
    }

    func popNavigation(session: String) async -> Bool {
        await onQueue {
            guard session == self.session else { return false }
            var popped = false
            self.guarded { popped = try $0.call("tinycast_pop")?.toInt32() == 1 }
            return popped
        }
    }

    func runToastAction(token: String) async {
        await onQueue { self.guarded { try $0.call("tinycast_toast_action", [.text(token)]) } }
    }

    func stop(session: String) async {
        await onQueue {
            guard session == self.session else { return }
            self.guarded { try $0.call("tinycast_stop") }
            self.session = nil
        }
    }

    func drainHostCalls() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.hostTasks.isEmpty {
                    continuation.resume()
                } else {
                    self.idleWaiters.append(continuation)
                }
            }
        }
    }

    func shutdown() {
        let hostAPI = hostAPI
        Task { @MainActor in hostAPI.sessionEnded() }
        queue.async {
            self.session = nil
            self.tearDown()
        }
    }
}
