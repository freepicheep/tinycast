import Darwin
import Foundation
import os

/// The app's end of the plugin helper, the process plugin code runs in (`PluginHelper`). It starts
/// the helper on the first launch or scan, and again after the helper exits: when idle, when it
/// grew, when it crashed, or when the watchdog ended it. Every runtime the Extensions host asks for
/// is a `RemotePluginRuntime` whose session runs there.
@MainActor
final class PluginHelperClient {
    /// The helper must answer a ping within this, or it's taken for stuck and ended. Generous: a
    /// launch compiles on the helper's main thread, and a cold compile of the kit takes seconds.
    static let watchdogTimeout: Duration = .seconds(10)
    static let watchdogInterval: Duration = .seconds(2)

    private let executable: URL
    /// The app's compile cache, which the helper shares.
    private let cacheDirectory: URL
    private var link: ProcessLink<PluginHelperRequest, PluginHelperEvent>?
    private var runtimes: [Int: RemotePluginRuntime] = [:]
    private var replies: [Int: CheckedContinuation<PluginHelperReply?, Never>] = [:]
    private var nextNumber = 1
    private var watchdog: Task<Void, Never>?
    /// The footprint the helper last reported, for Settings and the bench.
    private(set) var footprint = 0
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.abueammar.tinycast", category: "PluginHelper")

    init(executable: URL, cacheDirectory: URL) {
        self.executable = executable
        self.cacheDirectory = cacheDirectory
    }

    static var bundledExecutable: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/PluginHelper", directoryHint: .notDirectory)
    }

    /// Whether this build has the helper: a build without it runs plugins in the app.
    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    var isRunning: Bool { link?.isOpen == true }

    // MARK: - Requests

    func number() -> Int {
        defer { nextNumber += 1 }
        return nextNumber
    }

    /// Sends a request that waits for its answer; nil when the helper couldn't start or ended first.
    func request(_ make: (Int) -> PluginHelperRequest) async -> PluginHelperReply? {
        guard let link = connected() else { return nil }
        let reply = number()
        let request = make(reply)
        return await withCheckedContinuation { continuation in
            replies[reply] = continuation
            link.send(request)
        }
    }

    func send(_ request: PluginHelperRequest) {
        link?.send(request)
    }

    func register(_ runtime: RemotePluginRuntime) -> Int {
        let id = number()
        runtimes[id] = runtime
        return id
    }

    func unregister(_ id: Int) {
        runtimes.removeValue(forKey: id)
        if runtimes.isEmpty { stopWatchdog() }
    }

    /// Every plugin folder with its manifest, read in the helper: a manifest is plugin code too.
    func scan(_ directory: URL, description: URL?, cache: URL?) async -> [InstalledPlugin]? {
        let reply = await request {
            .scan(reply: $0, directory: directory.path, description: description?.path, cache: cache?.path)
        }
        guard case .scanned(let found) = reply else { return nil }
        return found.map { scanned in
            let directory = URL(filePath: scanned.directory, directoryHint: .isDirectory)
            if let data = scanned.manifest, let manifest = try? PluginManifest.decode(data) {
                return InstalledPlugin(directory: directory, manifest: .success(manifest))
            }
            return InstalledPlugin(
                directory: directory,
                manifest: .failure(scanned.error ?? .unreadable("the plugin helper couldn't read it")))
        }
    }

    // MARK: - The process

    private func connected() -> ProcessLink<PluginHelperRequest, PluginHelperEvent>? {
        if let link, link.isOpen { return link }
        do {
            let made = try ProcessLink<PluginHelperRequest, PluginHelperEvent>.spawn(
                executable, arguments: [cacheDirectory.path])
            made.onReceive = { [weak self] event in self?.receive(event) }
            made.onClose = { [weak self, weak made] error in
                guard let self, let made, self.link === made else { return }
                self.closed(error)
            }
            made.start()
            link = made
            return made
        } catch {
            logger.error("The plugin helper didn't start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The helper exited: what waited for it gets nothing, and running sessions fail.
    private func closed(_ error: (any Error)?) {
        link = nil
        stopWatchdog()
        let waiting = replies
        replies = [:]
        for continuation in waiting.values { continuation.resume(returning: nil) }
        let running = runtimes
        runtimes = [:]
        for runtime in running.values { runtime.helperStopped() }
    }

    /// Ends the helper at once; the next launch starts another.
    func terminate() {
        guard let pid = link?.childProcessIdentifier else { return }
        kill(pid, SIGKILL)
    }

    // MARK: - Events

    private func receive(_ event: PluginHelperEvent) {
        switch event {
        case .reply(let number, let reply):
            replies.removeValue(forKey: number)?.resume(returning: reply)
        case .rendered(let id, let session, let tree):
            runtimes[id]?.rendered(session: session, tree: tree)
        case .failed(let id, let session, let message):
            runtimes[id]?.failed(session: session, message: message)
        case .navigationDepth(let id, let session, let depth):
            runtimes[id]?.navigationDepth(session: session, depth: depth)
        case .finished(let id, let session):
            runtimes[id]?.finished(session: session)
        case .log(let id, let level, let message):
            runtimes[id]?.log(level: level, message: message)
        case .hostCall(let id, let call, let api, let method, let arguments):
            guard let runtime = runtimes[id] else {
                send(
                    .hostAnswer(
                        call: call, result: nil,
                        error: ExtensionHostError.noActiveExtension.localizedDescription))
                return
            }
            Task {
                do {
                    let result = try await runtime.perform(api: api, method: method, arguments: arguments)
                    self.send(.hostAnswer(call: call, result: result, error: nil))
                } catch {
                    self.send(
                        .hostAnswer(
                            call: call, result: nil,
                            error: (error as? LocalizedError)?.errorDescription ?? String(describing: error)))
                }
            }
        case .sessionEnded:
            // `RemotePluginRuntime.shutdown` ends the host session itself, before the helper hears.
            break
        case .storage(let id, let write):
            runtimes[id]?.store(write)
        case .footprint(let bytes, _):
            footprint = bytes
        }
    }

    // MARK: - Watchdog

    /// While a session runs, a ping every couple of seconds; one unanswered past the timeout means
    /// the helper's main thread is stuck (a host function that never returns, a loop Scrift's
    /// limits didn't reach), so it's ended and its sessions fail.
    func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchdogInterval)
                guard let self, !Task.isCancelled, self.isRunning, !self.runtimes.isEmpty else { continue }
                let answered = await self.pingAnswered()
                if !answered, !Task.isCancelled, self.isRunning {
                    self.logger.error("The plugin helper stopped answering; ending it")
                    self.terminate()
                }
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func pingAnswered() async -> Bool {
        let answer = Task { await self.request { .ping(reply: $0) } != nil }
        let timeout = Task {
            try? await Task.sleep(for: Self.watchdogTimeout)
        }
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await answer.value }
            group.addTask {
                await timeout.value
                return nil
            }
            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            timeout.cancel()
            return first ?? false
        }
    }
}

/// One plugin command whose session runs in the plugin helper. The Extensions host drives it as
/// it drives any runtime; it forwards each call as a frame, and answers the helper's host calls
/// and storage writes with the app's own `ExtensionHostAPI` and `ExtensionStorage`.
@MainActor
final class RemotePluginRuntime: ExtensionCommandRuntime {
    private let client: PluginHelperClient
    private let plugin: PluginManifest
    private let directory: URL
    private let storage: ExtensionStorage
    private let hostAPI: ExtensionHostAPI
    private let appScheme: String
    private let kitDirectory: URL?
    private weak var delegate: ExtensionRuntimeDelegate?
    private var id: Int?
    private var session: String?

    init(
        client: PluginHelperClient, plugin: PluginManifest, directory: URL, storage: ExtensionStorage,
        hostAPI: ExtensionHostAPI, appScheme: String, kitDirectory: URL? = PluginCatalog.kitDirectory()
    ) {
        self.kitDirectory = kitDirectory
        self.client = client
        self.plugin = plugin
        self.directory = directory
        self.storage = storage
        self.hostAPI = hostAPI
        self.appScheme = appScheme
    }

    func setDelegate(_ delegate: ExtensionRuntimeDelegate) {
        self.delegate = delegate
    }

    func boot(config: ExtensionBootConfig) async throws {}

    func launch(
        session: String, owner: InstalledExtension, command: ExtensionCommand,
        context: ExtensionLaunchContext
    ) async throws {
        guard let kit = kitDirectory else { throw PluginLaunchError(.kitMissing) }
        if let id { client.unregister(id) }
        let id = client.register(self)
        self.id = id
        self.session = session
        let launch = PluginHelperLaunch(
            session: session, commandName: command.name, manifest: plugin.json(),
            pluginDirectory: directory.path,
            kitDirectory: kit.path, context: context, appScheme: appScheme,
            storage: PluginStorageSnapshot(of: plugin.hostName, in: storage))
        let reply = await client.request { .launch(runtime: id, reply: $0, launch: launch) }
        switch reply {
        case .done?:
            client.startWatchdog()
        case .launchFailed(let message)?:
            end()
            throw PluginLaunchError(message: message)
        default:
            end()
            throw PluginLaunchError(message: "The plugin helper didn't start, so the command can't run.")
        }
    }

    func dispatch(session: String, handler: String, payload: String, completesSession: Bool) async {
        guard let id, session == self.session else {
            if completesSession { delegate?.runtime(self, session: session, didFinish: ()) }
            return
        }
        _ = await client.request {
            .dispatch(
                runtime: id, reply: $0, session: session, handler: handler, payload: payload,
                completesSession: completesSession)
        }
    }

    func popNavigation(session: String) async -> Bool {
        guard let id, session == self.session else { return false }
        guard
            case .popped(let popped)? = await client.request({
                .pop(runtime: id, reply: $0, session: session)
            })
        else {
            return false
        }
        return popped
    }

    func runToastAction(token: String) async {
        guard let id else { return }
        _ = await client.request { .toastAction(runtime: id, reply: $0, token: token) }
    }

    func stop(session: String) async {
        guard let id, session == self.session else { return }
        _ = await client.request { .stop(runtime: id, reply: $0, session: session) }
        self.session = nil
    }

    func drainHostCalls() async {
        guard let id else { return }
        _ = await client.request { .drain(runtime: id, reply: $0) }
    }

    func shutdown() {
        if let id { client.send(.shutdown(runtime: id)) }
        end()
        hostAPI.sessionEnded()
    }

    private func end() {
        if let id { client.unregister(id) }
        id = nil
        session = nil
    }

    // MARK: - From the helper

    func rendered(session: String, tree: RenderTree) {
        delegate?.runtime(self, session: session, didRender: tree)
    }

    func failed(session: String, message: String) {
        if session == self.session { self.session = nil }
        delegate?.runtime(self, session: session, didFail: message)
    }

    func navigationDepth(session: String, depth: Int) {
        delegate?.runtime(self, session: session, navigationDepth: depth)
    }

    func finished(session: String) {
        delegate?.runtime(self, session: session, didFinish: ())
    }

    func log(level: String, message: String) {
        delegate?.runtime(self, log: level, message: message)
    }

    func perform(api: String, method: String, arguments: [RenderValue]) async throws -> String {
        try await hostAPI.perform(api: api, method: method, arguments: arguments)
    }

    func store(_ write: PluginStorageWrite) {
        write.apply(to: storage, extension: plugin.hostName)
    }

    /// The helper exited under the session: it ends with the reason, as a crash in the app would.
    func helperStopped() {
        id = nil
        guard let session else { return }
        self.session = nil
        delegate?.runtime(
            self, session: session,
            didFail:
                "The plugin stopped: its process ended (it crashed, ran out of memory, or stopped responding)."
        )
    }
}
