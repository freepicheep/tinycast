import Darwin
import Foundation
import Scrift

/// The process plugin code runs in, so a plugin that crashes, leaks or spins takes only this down,
/// and its memory goes back to the system when it exits. The app starts it with `ProcessLink` and
/// reaches it only through `PluginHelperRequest`s; everything a plugin asks of the app (the
/// clipboard, Accessibility, opening URLs, toasts, its storage) comes back as an event the app
/// answers. It holds no plugin state between launches but its compile cache.
@main
enum PluginHelper {
    @MainActor private static var host: PluginHelperHost?

    static func main() {
        MainActor.assumeIsolated {
            guard let link = ProcessLink<PluginHelperEvent, PluginHelperRequest>.standardIO() else { exit(2) }
            // The app's compile cache, which a tool without a bundle identifier can't work out:
            // a Dev build's is its own.
            let cache = CommandLine.arguments.dropFirst().first.map {
                URL(filePath: $0, directoryHint: .isDirectory)
            }
            let made = PluginHelperHost(link: link, moduleCacheDirectory: cache)
            made.start()
            host = made
        }
        // Not `dispatchMain()`, which parks this thread and drains the main queue on another: main
        // actor host types check that they run on the main thread itself.
        RunLoop.main.run()
    }
}

/// Runs the runtimes the app asks for and carries their callbacks back.
@MainActor
final class PluginHelperHost {
    /// How long the helper waits with nothing running before it exits, giving its memory back.
    static let idleLifetime: Duration = .seconds(90)
    /// Past this footprint the helper exits as soon as nothing runs, rather than keep the pages a
    /// heavy plugin grew; the next launch starts a fresh one.
    static let recycleFootprint = 768 << 20
    /// Compiled modules kept in memory besides those running: the kit and the plugins used lately.
    /// The helper is short-lived, so this is memory for at most its idle lifetime.
    static let moduleCapacity = 12

    private let link: ProcessLink<PluginHelperEvent, PluginHelperRequest>
    private var runtimes: [Int: Running] = [:]
    private var calls: [Int: CheckedContinuation<String, any Error>] = [:]
    private var nextCall = 1
    private var idleExit: Task<Void, Never>?
    private var kits: [String: PluginSources] = [:]
    /// The app's compile cache folder, which this process shares: a plugin compiled once is a
    /// lookup in either.
    private let moduleCache: ScriftModuleCache

    private struct Running {
        let runtime: ScriftPluginRuntime
        let delegate: Delegate
        let hostAPI: HostAPI
    }

    init(link: ProcessLink<PluginHelperEvent, PluginHelperRequest>, moduleCacheDirectory: URL?) {
        self.link = link
        moduleCache = ScriftModuleCache(capacity: Self.moduleCapacity, directory: moduleCacheDirectory)
    }

    func start() {
        link.onReceive = { [weak self] request in self?.receive(request) }
        // The app is gone, or let the helper go: nothing here outlives it.
        link.onClose = { _ in exit(0) }
        link.start()
        scheduleIdleExit()
    }

    func send(_ event: PluginHelperEvent) {
        link.send(event)
    }

    // MARK: - Requests

    private func receive(_ request: PluginHelperRequest) {
        switch request {
        case .launch(let id, let reply, let launch):
            idleExit?.cancel()
            Task { await self.launch(id, reply: reply, launch) }
        case .dispatch(let id, let reply, let session, let handler, let payload, let completesSession):
            Task {
                await self.runtimes[id]?.runtime.dispatch(
                    session: session, handler: handler, payload: payload, completesSession: completesSession)
                self.send(.reply(reply, .done))
            }
        case .pop(let id, let reply, let session):
            Task {
                let popped = await self.runtimes[id]?.runtime.popNavigation(session: session) ?? false
                self.send(.reply(reply, .popped(popped)))
            }
        case .toastAction(let id, let reply, let token):
            Task {
                await self.runtimes[id]?.runtime.runToastAction(token: token)
                self.send(.reply(reply, .done))
            }
        case .stop(let id, let reply, let session):
            Task {
                await self.runtimes[id]?.runtime.stop(session: session)
                self.send(.reply(reply, .done))
            }
        case .drain(let id, let reply):
            Task {
                await self.runtimes[id]?.runtime.drainHostCalls()
                self.send(.reply(reply, .done))
            }
        case .shutdown(let id):
            runtimes.removeValue(forKey: id)?.runtime.shutdown()
            runtimeEnded()
        case .hostAnswer(let call, let result, let error):
            guard let continuation = calls.removeValue(forKey: call) else { return }
            if let result {
                continuation.resume(returning: result)
            } else {
                continuation.resume(
                    throwing: PluginHelperHostError(message: error ?? "The app didn't answer."))
            }
        case .scan(let reply, let directory, let description, let cache):
            Task {
                self.send(
                    .reply(
                        reply, .scanned(await Self.scan(directory, description: description, cache: cache))))
            }
        case .warm(let kitDirectory):
            Task { await self.warm(kitDirectory) }
        case .exitWhenIdle:
            if runtimes.isEmpty { exit(0) }
        case .ping(let reply):
            send(.reply(reply, .done))
        }
    }

    private func launch(_ id: Int, reply: Int, _ launch: PluginHelperLaunch) async {
        let manifest: PluginManifest
        do {
            manifest = try PluginManifest.decode(launch.manifest)
        } catch {
            send(
                .reply(
                    reply, .launchFailed("The plugin helper couldn't read the plugin's manifest: \(error)")))
            return
        }
        let hostAPI = HostAPI(host: self, runtime: id)
        let storage = PluginStorageMirror(launch.storage) { [weak self] write in
            self?.send(.storage(runtime: id, write: write))
        }
        let kitDirectory = launch.kitDirectory
        let runtime = ScriftPluginRuntime(
            plugin: manifest, directory: URL(filePath: launch.pluginDirectory, directoryHint: .isDirectory),
            storage: storage, hostAPI: hostAPI, appScheme: launch.appScheme, moduleCache: moduleCache,
            kitSources: { [weak self] in await self?.kit(at: kitDirectory) })
        let delegate = Delegate(host: self, runtime: id)
        runtime.setDelegate(delegate)
        runtimes[id] = Running(runtime: runtime, delegate: delegate, hostAPI: hostAPI)
        do {
            try await runtime.launch(
                session: launch.session, commandName: launch.commandName, context: launch.context)
            send(.reply(reply, .done))
        } catch {
            // Nothing of a failed launch is kept; the app forgets it too.
            runtimes.removeValue(forKey: id)?.runtime.shutdown()
            send(
                .reply(
                    reply,
                    .launchFailed((error as? LocalizedError)?.errorDescription ?? String(describing: error))))
            runtimeEnded()
        }
    }

    private func warm(_ kitDirectory: String) async {
        guard let kit = await kit(at: kitDirectory) else { return }
        let context = ScriftContext(
            modules: PluginCapabilities.modules(for: []), cache: moduleCache, output: { _ in })
        // Compiled off the main thread (Scrift's async load), so pings still answer.
        _ = try? await context.load(
            files: kit.files.map { SourceFile(name: $0.name, text: $0.text) }, moduleName: "Tinycast")
    }

    /// The kit's sources, read once per helper: the bundle's files don't change under it.
    private func kit(at path: String) async -> PluginSources? {
        if let kit = kits[path] { return kit }
        let read = await Task.detached(priority: .userInitiated) {
            try? PluginSources.read(
                from: URL(filePath: path, directoryHint: .isDirectory), requiringMain: false)
        }.value
        kits[path] = read
        return read
    }

    private nonisolated static func scan(
        _ directory: String, description: String?, cache: String?
    ) async -> [PluginHelperScanned] {
        await Task.detached(priority: .utility) {
            let directoryURL = URL(filePath: directory, directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let sources = description.flatMap {
                try? PluginSources.read(
                    from: URL(filePath: $0, directoryHint: .isDirectory), requiringMain: false)
            }
            let found = PluginCatalog.scan(
                directoryURL, description: sources,
                cache: cache.map { URL(filePath: $0, directoryHint: .isDirectory) })
            return found.map { plugin in
                switch plugin.manifest {
                case .success(let manifest):
                    PluginHelperScanned(
                        directory: plugin.directory.path, manifest: manifest.json(), error: nil)
                case .failure(let error):
                    PluginHelperScanned(directory: plugin.directory.path, manifest: nil, error: error)
                }
            }
        }.value
    }

    // MARK: - Host calls

    /// A call to the app's host API, answered by a `hostAnswer` frame.
    func hostCall(runtime: Int, api: String, method: String, arguments: [RenderValue]) async throws -> String
    {
        let call = nextCall
        nextCall += 1
        return try await withCheckedThrowingContinuation { continuation in
            calls[call] = continuation
            send(.hostCall(runtime: runtime, call: call, api: api, method: method, arguments: arguments))
        }
    }

    // MARK: - Lifetime

    private func runtimeEnded() {
        let footprint = Self.footprint()
        send(.footprint(bytes: footprint, runtimes: runtimes.count))
        guard runtimes.isEmpty else { return }
        // A helper that grew past the line goes entirely, and its pages with it.
        if footprint > Self.recycleFootprint { exit(0) }
        scheduleIdleExit()
    }

    private func scheduleIdleExit() {
        idleExit?.cancel()
        idleExit = Task { [weak self] in
            try? await Task.sleep(for: Self.idleLifetime)
            guard !Task.isCancelled, let self, self.runtimes.isEmpty else { return }
            exit(0)
        }
    }

    /// The process's physical footprint, as Activity Monitor's Memory column shows it.
    nonisolated static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    // MARK: - The runtime's two seams

    /// The runtime's host API: every call is a frame to the app and back.
    @MainActor
    final class HostAPI: ExtensionHostAPI {
        private weak var host: PluginHelperHost?
        private let runtime: Int

        init(host: PluginHelperHost, runtime: Int) {
            self.host = host
            self.runtime = runtime
        }

        func perform(api: String, method: String, arguments: [RenderValue]) async throws -> String {
            guard let host else { throw PluginHelperHostError(message: "The plugin helper is stopping.") }
            return try await host.hostCall(runtime: runtime, api: api, method: method, arguments: arguments)
        }

        func sessionEnded() {
            host?.send(.sessionEnded(runtime: runtime))
        }
    }

    /// The runtime's delegate: each callback is a frame to the app.
    @MainActor
    final class Delegate: ExtensionRuntimeDelegate {
        private weak var host: PluginHelperHost?
        private let runtime: Int

        init(host: PluginHelperHost, runtime: Int) {
            self.host = host
            self.runtime = runtime
        }

        func runtime(_ runtime: any ExtensionCommandRuntime, session: String, didRender tree: RenderTree) {
            host?.send(.rendered(runtime: self.runtime, session: session, tree: tree))
        }

        func runtime(_ runtime: any ExtensionCommandRuntime, session: String, didFail message: String) {
            host?.send(.failed(runtime: self.runtime, session: session, message: message))
        }

        func runtime(_ runtime: any ExtensionCommandRuntime, session: String, navigationDepth: Int) {
            host?.send(.navigationDepth(runtime: self.runtime, session: session, depth: navigationDepth))
        }

        func runtime(_ runtime: any ExtensionCommandRuntime, session: String, didFinish: Void) {
            host?.send(.finished(runtime: self.runtime, session: session))
        }

        func runtime(_ runtime: any ExtensionCommandRuntime, log level: String, message: String) {
            host?.send(.log(runtime: self.runtime, level: level, message: message))
        }
    }
}

/// The app's error for a host call, as its message.
struct PluginHelperHostError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
