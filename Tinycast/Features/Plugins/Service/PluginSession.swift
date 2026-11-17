import Foundation
import Stir

/// One command of one plugin, running: its own Stir context, so nothing is shared between plugins
/// or kept from one launch to the next. Everything happens on the main actor, inside limits.
@MainActor
final class PluginSession {
    enum State {
        case running(PluginPage)
        /// An action command finished; the palette closes.
        case finished
        case failed(String)
    }

    let pluginName: String
    let command: PluginCommand
    private(set) var state: State = .failed("")
    /// Told after every change of `state`.
    var onChange: () -> Void = {}

    /// Per script call (a render, an action, a search keystroke) and per task step: a plugin that
    /// loops forever panics after a second instead of freezing the palette.
    static let limits = StirLimits.untrusted

    private let context: StirContext
    private let kit: StirModule
    private let module: StirModule
    private let environment: PluginEnvironment
    private let render: () throws -> PluginPage
    private let pop: () throws -> Bool
    private let depth: () throws -> Int
    private let end: () throws -> Void
    private var renderScheduled = false
    private var pump: Task<Void, Never>?
    private var isClosed = false
    private let log: PluginOutput

    /// Compiles and runs the kit and the plugin's `main.swift`, then opens or runs `command`.
    init(
        manifest: PluginManifest, command: PluginCommand, sources: PluginSources,
        kit kitSources: PluginSources, storage: PluginStorage, services: any PluginHostServices
    ) throws(PluginSessionError) {
        pluginName = manifest.name
        self.command = command
        var modules = [
            PluginSession.hostModule,
            PluginCapabilities.foundation(network: manifest.permissions.contains(.network))
        ]
        if manifest.permissions.contains(.clipboard) { modules.append(PluginCapabilities.appKit) }
        let log = PluginOutput()
        self.log = log
        context = StirContext(modules: modules, output: { log.append($0) })
        let limits = Self.limits
        do {
            kit = try context.load(
                files: kitSources.files.map { SourceFile(name: $0.name, text: $0.text) },
                moduleName: "Tinycast")
            try kit.run(limits: limits)
            module = try context.load(
                files: sources.files.map { SourceFile(name: $0.name, text: $0.text) },
                moduleName: InstalledPlugin.moduleName(for: manifest.name))
            render = try kit.function("_tinycastRender", as: (() throws -> PluginPage).self, limits: limits)
            pop = try kit.function("_tinycastPop", as: (() throws -> Bool).self, limits: limits)
            depth = try kit.function("_tinycastDepth", as: (() throws -> Int).self, limits: limits)
            end = try kit.function("_tinycastEnd", as: (() throws -> Void).self, limits: limits)
        } catch let error as StirCompileError {
            throw .compile(error.description)
        } catch let panic as StirPanic {
            throw .panic(panic.description)
        } catch {
            throw .internal(String(describing: error))
        }
        environment = .make(
            plugin: manifest.name, command: command.name, storage: storage, services: services,
            onInvalidate: {})
        environment.setInvalidationHandler { [weak self] in self?.scheduleRender() }

        do {
            try module.run(limits: limits)
            let begin = try kit.function(
                "_tinycastBegin", as: ((PluginEnvironment) throws -> Void).self, limits: limits)
            try begin(environment)
        } catch let panic as StirPanic {
            throw .panic(panic.description)
        } catch {
            throw .internal(String(describing: error))
        }
    }

    /// The host types every plugin's kit renders into; plugins see them only through the kit.
    static var hostModule: StirHostModule {
        StirHostModule(
            "_TinycastHost",
            exports: [
                PluginPage.self, PluginList.self, PluginSearch.self, PluginSection.self,
                PluginItem.self, PluginIcon.self, PluginDetail.self, PluginMetadataEntry.self,
                PluginAction.self, PluginActionKind.self, PluginEnvironment.self
            ])
    }

    /// Opens a view command's first screen.
    func open() async {
        do {
            let open = try kit.function("_tinycastOpen", as: ((String) throws -> Bool).self, limits: Self.limits)
            guard try open(command.name) else {
                return fail(PluginSessionError.unregistered(command.name).description)
            }
        } catch {
            return fail(error)
        }
        renderNow()
        pumpTasks()
    }

    /// Runs an action command to the end, tasks it starts included.
    func run() async {
        do {
            let run = try kit.function(
                "_tinycastRun", as: ((String) async throws -> Bool).self, limits: Self.limits)
            guard try await run(command.name) else {
                return fail(PluginSessionError.unregistered(command.name).description)
            }
            try await module.waitForTasks(limits: Self.limits)
            try await kit.waitForTasks(limits: Self.limits)
        } catch {
            return fail(error)
        }
        guard !isClosed else { return }
        state = .finished
        onChange()
    }

    /// Calls into the script on the user's behalf: an action's closure, a search keystroke.
    func call(_ body: () throws -> Void) {
        guard !isClosed else { return }
        do {
            try body()
        } catch {
            return fail(error)
        }
        flushRender()
        pumpTasks()
    }

    /// Escape on a pushed screen; false at the root, where Escape leaves the command.
    func goBack() -> Bool {
        guard !isClosed, (try? depth()) ?? 1 > 1 else { return false }
        call { _ = try pop() }
        return true
    }

    var navigationDepth: Int { isClosed ? 1 : (try? depth()) ?? 1 }

    /// What the plugin printed, for its error screen and the console.
    var output: String { log.text }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        pump?.cancel()
        pump = nil
        try? end()
        environment.detach()
        context.interruptHandle.interrupt()
    }

    // MARK: - Rendering

    private func scheduleRender() {
        guard !renderScheduled, !isClosed else { return }
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
        guard !isClosed else { return }
        do {
            state = .running(try render())
        } catch {
            return fail(error)
        }
        onChange()
    }

    /// Runs the tasks a call started (a `.task`, a `Task { }` in an action) as they become ready.
    private func pumpTasks() {
        guard pump == nil, !isClosed,
            kit.pendingTaskCount() + module.pendingTaskCount() > 0
        else { return }
        pump = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                while !self.isClosed, self.kit.pendingTaskCount() + self.module.pendingTaskCount() > 0 {
                    try await self.kit.waitForTasks(limits: Self.limits)
                    try await self.module.waitForTasks(limits: Self.limits)
                    self.flushRender()
                    // Neither module can run until the host's clock or a task elsewhere moves.
                    if self.kit.pendingTaskCount() + self.module.pendingTaskCount() > 0 {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self.fail(error)
            }
            self.pump = nil
            self.flushRender()
        }
    }

    private func fail(_ error: any Error) {
        switch error {
        case let panic as StirPanic: fail(PluginSessionError.panic(panic.description).description)
        case let thrown as StirScriptError: fail("The command threw an error: \(thrown.description)")
        default: fail(String(describing: error))
        }
    }

    private func fail(_ message: String) {
        guard !isClosed else { return }
        state = .failed(message)
        onChange()
    }
}

enum PluginSessionError: Error, CustomStringConvertible {
    case sources(String)
    case compile(String)
    case panic(String)
    case unregistered(String)
    case kitMissing
    case `internal`(String)

    var description: String {
        switch self {
        case .sources(let reason): reason
        case .compile(let diagnostics): diagnostics
        case .panic(let panic): "The plugin stopped: \(panic)"
        case .unregistered(let name):
            "main.swift doesn't register “\(name)”: add Plugin.command(\"\(name)\") { … }"
        case .kitMissing: "The plugin kit is missing from the app bundle."
        case .internal(let reason): reason
        }
    }
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
