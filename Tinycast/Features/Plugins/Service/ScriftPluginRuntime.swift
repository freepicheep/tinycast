import Foundation
import Scrift

/// One plugin command, running in a Scrift context of its own: the kit, the plugin's module and the
/// host APIs its manifest grants. Nothing is shared between plugins or kept from one launch to
/// the next. Everything happens on the main actor, inside `limits`.
@MainActor
final class ScriftPluginRuntime: ExtensionCommandRuntime {
    /// Per script call (a render, an action, a keystroke) and per task step: a plugin that loops
    /// forever panics after a second instead of freezing the palette.
    static let limits = ScriftLimits.untrusted

    private let plugin: PluginManifest
    private let directory: URL
    private let kitSources: @MainActor () async -> PluginSources?
    private let storage: ExtensionStorage
    private let hostAPI: ExtensionHostAPI
    private let appScheme: String
    private let moduleCache: ScriftModuleCache
    private weak var delegate: ExtensionRuntimeDelegate?

    private var session: String?
    private var loaded: Loaded?
    private var renderer = PluginRenderer()
    private var renderScheduled = false
    private var pump: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private let output = PluginOutput()

    /// What a launch compiled: the context and the kit's entry points.
    private struct Loaded {
        let context: ScriftContext
        let kit: ScriftModule
        let module: ScriftModule
        let environment: PluginEnvironment
        let render: () throws -> PluginNode?
        let depth: () throws -> Int
        let pop: () throws -> Bool
        let end: () throws -> Void

        var pendingTasks: Int { kit.pendingTaskCount() + module.pendingTaskCount() }
    }

    init(
        plugin: PluginManifest, directory: URL, storage: ExtensionStorage, hostAPI: ExtensionHostAPI,
        appScheme: String, moduleCache: ScriftModuleCache = .shared,
        kitSources: @escaping @MainActor () async -> PluginSources?
    ) {
        self.appScheme = appScheme
        self.moduleCache = moduleCache
        self.plugin = plugin
        self.directory = directory
        self.storage = storage
        self.hostAPI = hostAPI
        self.kitSources = kitSources
    }

    func setDelegate(_ delegate: ExtensionRuntimeDelegate) {
        self.delegate = delegate
    }

    /// The kit compiles per launch, against that launch's permissions.
    func boot(config: ExtensionBootConfig) async throws {}

    // MARK: - Launching

    func launch(
        session: String, owner: InstalledExtension, command: ExtensionCommand,
        context: ExtensionLaunchContext
    ) async throws {
        guard let declared = plugin.commands.first(where: { $0.name == command.name }) else {
            throw ExtensionLaunchError.unknownCommand(command.name)
        }
        let directory = directory
        let read = await Task.detached(priority: .userInitiated) {
            Result { () throws(PluginSources.ReadError) -> PluginSources in try PluginSources.read(from: directory) }
        }.value
        guard let kit = await kitSources() else { throw PluginLaunchError(PluginSessionError.kitMissing) }
        let sources: PluginSources
        switch read {
        case .success(let value): sources = value
        case .failure(let error): throw PluginLaunchError(.sources(error.description))
        }
        self.session = session
        do {
            loaded = try load(kit: kit, sources: sources, command: declared, context: context)
        } catch {
            self.session = nil
            throw PluginLaunchError(error, output: output.text)
        }
        switch declared.mode {
        case .view, .menuBar: open(declared.name)
        case .action:
            // Runs after the launch returns, as a JavaScript command's promise does.
            Task { @MainActor [weak self] in await self?.run(declared.name) }
        }
    }

    private func load(
        kit kitSources: PluginSources, sources: PluginSources, command: PluginCommand,
        context launch: ExtensionLaunchContext
    ) throws(PluginSessionError) -> Loaded {
        let output = output
        let compiled = try Self.compile(
            plugin: plugin, kit: kitSources, sources: sources, hostAPI: hostAPI, cache: moduleCache,
            output: { output.append($0) })
        let limits = Self.limits
        return try Self.catching { () throws -> Loaded in
            let environment = PluginEnvironment.make(
                plugin: plugin, command: command.name, storage: storage, hostAPI: hostAPI,
                appScheme: appScheme, onInvalidate: { [weak self] in self?.scheduleRender() },
                onError: { [weak self] in self?.fail($0) })
            let kit = compiled.kit
            let begin = try kit.function(
                "_tinycastBegin", as: ((PluginEnvironment, PluginLaunch) throws -> Void).self, limits: limits)
            try begin(environment, PluginLaunch(launch, command: command.name))
            return Loaded(
                context: compiled.context, kit: kit, module: compiled.module, environment: environment,
                render: try kit.function("_tinycastRender", as: (() throws -> PluginNode?).self, limits: limits),
                depth: try kit.function("_tinycastDepth", as: (() throws -> Int).self, limits: limits),
                pop: try kit.function("_tinycastPop", as: (() throws -> Bool).self, limits: limits),
                end: try kit.function("_tinycastEnd", as: (() throws -> Void).self, limits: limits))
        }
    }

    /// The kit and the plugin, compiled against the manifest's permissions and run to the end of
    /// `main.swift`, whose registrations must match the manifest's commands. No command starts:
    /// `tinycast-plugin dump` checks a plugin with this alone.
    static func compile(
        plugin: PluginManifest, kit kitSources: PluginSources, sources: PluginSources,
        hostAPI: ExtensionHostAPI, cache: ScriftModuleCache? = .shared, output: @escaping (String) -> Void
    ) throws(PluginSessionError) -> (context: ScriftContext, kit: ScriftModule, module: ScriftModule) {
        let context = ScriftContext(
            modules: PluginCapabilities.modules(for: plugin.permissions), cache: cache, output: output)
        let limits = Self.limits
        return try catching { () throws -> (context: ScriftContext, kit: ScriftModule, module: ScriftModule) in
            let selection =
                plugin.permissions.contains(.selection)
                ? try PluginCapabilities.loadSelection(into: context, hostAPI: hostAPI) : nil
            let kit = try context.load(
                files: kitSources.files.map { SourceFile(name: $0.name, text: $0.text) }, moduleName: "Tinycast")
            try kit.run(limits: limits)
            let module = try withExtendedLifetime(selection) {
                try context.load(
                    files: sources.files.map { SourceFile(name: $0.name, text: $0.text) },
                    moduleName: InstalledPlugin.moduleName(for: plugin.name))
            }
            try module.run(limits: limits)
            let registered = try kit.function(
                "_tinycastRegistrations", as: (() throws -> [String: String]).self, limits: limits)()
            let problems = registrationProblems(declared: plugin.commands, registered: registered)
            guard problems.isEmpty else { throw PluginSessionError.registrations(problems) }
            return (context, kit, module)
        }
    }

    /// Scrift's errors, as the plugin's.
    private static func catching<T>(_ body: () throws -> T) throws(PluginSessionError) -> T {
        do {
            return try body()
        } catch let error as PluginSessionError {
            throw error
        } catch let error as ScriftCompileError {
            throw .compile(error.description)
        } catch let panic as ScriftPanic {
            throw .panic(panic.description)
        } catch {
            throw .internal(String(describing: error))
        }
    }

    /// Every way `main.swift`'s registrations differ from the manifest's commands, one line each.
    /// `registered` maps each registered name to the mode its `Plugin` call gave it.
    nonisolated static func registrationProblems(
        declared: [PluginCommand], registered: [String: String]
    ) -> [String] {
        var problems: [String] = []
        for command in declared {
            guard let mode = registered[command.name] else {
                problems.append(PluginSessionError.unregistered(command.name, command.mode).description)
                continue
            }
            if mode != command.mode.rawValue {
                problems.append(
                    "“\(command.name)” is \(command.mode.article) in Manifest.swift, but main.swift registers it with \(PluginCommand.Mode(rawValue: mode)?.registration ?? mode)"
                )
            }
        }
        let names = Set(declared.map(\.name))
        for name in Set(registered.keys).subtracting(names).sorted() {
            problems.append("main.swift registers “\(name)”, which Manifest.swift doesn't declare")
        }
        return problems
    }

    private func open(_ name: String) {
        guard let loaded else { return }
        do {
            let open = try loaded.kit.function(
                "_tinycastOpen", as: ((String) throws -> Bool).self, limits: Self.limits)
            guard try open(name) else {
                return fail(PluginSessionError.unregistered(name, .view).description)
            }
        } catch {
            return fail(error)
        }
        renderNow()
        pumpTasks()
    }

    /// An action command runs to its end, the tasks it starts included.
    private func run(_ name: String) async {
        guard let loaded, let session else { return }
        do {
            let run = try loaded.kit.function(
                "_tinycastRun", as: ((String) async throws -> Bool).self, limits: Self.limits)
            guard try await run(name) else {
                return fail(PluginSessionError.unregistered(name, .action).description)
            }
            try await loaded.module.waitForTasks(limits: Self.limits)
            try await loaded.kit.waitForTasks(limits: Self.limits)
        } catch {
            return fail(error)
        }
        guard self.session == session else { return }
        delegate?.runtime(self, session: session, didFinish: ())
    }

    // MARK: - Events from the palette

    func dispatch(session: String, handler: String, payload: String, completesSession: Bool) async {
        guard session == self.session, let body = renderer.handlers[handler] else {
            if completesSession { delegate?.runtime(self, session: session, didFinish: ()) }
            return
        }
        let arguments = PluginRenderer.arguments(fromJSON: payload)
        call { try body(arguments) }
        guard completesSession else { return }
        await drainHostCalls()
        guard self.session == session else { return }
        delegate?.runtime(self, session: session, didFinish: ())
    }

    func popNavigation(session: String) async -> Bool {
        guard session == self.session, let loaded, (try? loaded.depth()) ?? 1 > 1 else { return false }
        var popped = false
        call { popped = try loaded.pop() }
        return popped
    }

    func runToastAction(token: String) async {
        guard let action = loaded?.environment.toastAction(token) else { return }
        call { try action() }
    }

    /// Calls into the script on the user's behalf, then renders what changed.
    private func call(_ body: () throws -> Void) {
        guard loaded != nil else { return }
        do {
            try body()
        } catch {
            return fail(error)
        }
        flushRender()
        pumpTasks()
    }

    func stop(session: String) async {
        guard session == self.session else { return }
        close()
    }

    func drainHostCalls() async {
        guard pump != nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    func shutdown() {
        close()
        hostAPI.sessionEnded()
    }

    private func close() {
        guard let loaded else { return }
        self.loaded = nil
        session = nil
        pump?.cancel()
        pump = nil
        try? loaded.end()
        loaded.environment.detach()
        loaded.context.interruptHandle.interrupt()
        resumeIdleWaiters()
    }

    // MARK: - Rendering

    private func scheduleRender() {
        guard !renderScheduled, loaded != nil else { return }
        renderScheduled = true
        // Coalesces every `@State` change one script call makes into one render after it.
        Task { @MainActor [weak self] in self?.flushRender() }
    }

    private func flushRender() {
        guard renderScheduled else { return }
        renderNow()
    }

    private func renderNow() {
        renderScheduled = false
        guard let loaded, let session else { return }
        let tree: RenderTree
        do {
            tree = renderer.tree(root: try loaded.render(), depth: try loaded.depth())
        } catch {
            return fail(error)
        }
        delegate?.runtime(self, session: session, didRender: tree)
        delegate?.runtime(self, session: session, navigationDepth: tree.depth)
    }

    /// Runs the tasks a call started (a `.task`, a `Task { }` in an action) as they become ready.
    private func pumpTasks() {
        guard pump == nil, let loaded, loaded.pendingTasks > 0 else { return }
        pump = Task { @MainActor [weak self] in
            do {
                while let self, let loaded = self.loaded, loaded.pendingTasks > 0, !Task.isCancelled {
                    try await loaded.kit.waitForTasks(limits: Self.limits)
                    try await loaded.module.waitForTasks(limits: Self.limits)
                    self.flushRender()
                    // Neither module can run until the host's clock or a task elsewhere moves.
                    if loaded.pendingTasks > 0 { try await Task.sleep(for: .milliseconds(10)) }
                }
            } catch is CancellationError {
                return
            } catch {
                self?.fail(error)
            }
            self?.pump = nil
            self?.flushRender()
            self?.resumeIdleWaiters()
        }
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func fail(_ error: any Error) {
        switch error {
        case let panic as ScriftPanic: fail(PluginSessionError.panic(panic.description).description)
        case let thrown as ScriftScriptError: fail("The command threw an error: \(thrown.description)")
        case let error as PluginSessionError: fail(error.description)
        default: fail((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    /// The error replaces the screen, with what the plugin printed before it.
    private func fail(_ message: String) {
        guard let session else { return }
        let printed = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = printed.isEmpty ? message : message + "\n\n" + printed
        close()
        delegate?.runtime(self, session: session, didFail: full)
    }
}

extension PluginLaunch {
    init(_ context: ExtensionLaunchContext, command: String) {
        self.init(
            commandName: command, launchType: context.launchType.rawValue, arguments: context.arguments,
            preferences: context.preferences.mapValues(PluginValue.init),
            fallbackText: context.fallbackText,
            launchContext: context.launchContext.mapValues(PluginValue.init),
            isDarkAppearance: context.isDarkAppearance)
    }
}

extension PluginValue {
    init(_ preference: ExtensionPreferenceValue) {
        switch preference {
        case .string(let text): self = .string(text)
        case .bool(let flag): self = .bool(flag)
        case .number(let number): self = .number(number)
        case .application(let path): self = .string(path)
        }
    }
}

extension PluginCommand.Mode {
    var article: String {
        switch self {
        case .view: "a view"
        case .action: "an action"
        case .menuBar: "a menu bar command"
        }
    }

    var registration: String {
        switch self {
        case .view: "Plugin.command"
        case .action: "Plugin.action"
        case .menuBar: "Plugin.menuBar"
        }
    }
}

/// A launch that failed before the command could run: compile errors with their lines, a panic,
/// registrations that disagree with the manifest.
struct PluginLaunchError: LocalizedError {
    let message: String

    init(_ error: PluginSessionError, output: String = "") {
        let printed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        message = printed.isEmpty ? error.description : error.description + "\n\n" + printed
    }

    var errorDescription: String? { message }
}

enum PluginSessionError: LocalizedError, CustomStringConvertible {
    case sources(String)
    case compile(String)
    case panic(String)
    case unregistered(String, PluginCommand.Mode)
    /// `main.swift` and the manifest disagree about the commands.
    case registrations([String])
    case kitMissing
    case `internal`(String)

    var description: String {
        switch self {
        case .sources(let reason): reason
        case .compile(let diagnostics): diagnostics
        case .panic(let panic): "The plugin stopped: \(panic)"
        case .unregistered(let name, let mode):
            "main.swift doesn't register “\(name)”: add \(mode.registration)(\"\(name)\") { … }"
        case .registrations(let problems): problems.joined(separator: "\n")
        case .kitMissing: "The plugin kit is missing from the app bundle."
        case .internal(let reason): reason
        }
    }

    var errorDescription: String? { description }
}

/// What a plugin prints, kept to the most recent 64 KB.
@MainActor
final class PluginOutput {
    private(set) var text = ""

    func append(_ chunk: String) {
        text += chunk
        if text.utf8.count > 64 << 10 { text = String(text.suffix(32 << 10)) }
    }
}
