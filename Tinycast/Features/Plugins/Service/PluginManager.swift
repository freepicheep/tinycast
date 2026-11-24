import CoreServices
import Foundation
import Scrift

/// Owns the installed plugins and hands their commands to the Extensions host, which runs them in
/// its palette, background and menu-bar lanes. Plugin code runs in the plugin helper, a process of
/// its own (`PluginHelperClient`), manifests included; a build without the helper, or one run with
/// `TINYCAST_PLUGINS_IN_PROCESS=1`, runs it in the app with `ScriftPluginRuntime`.
@MainActor
@Observable
final class PluginManager {
    private(set) var isEnabled = false
    /// Every plugin folder, a manifest that failed to read included, as Settings lists them.
    private(set) var installed: [InstalledPlugin] = []

    @ObservationIgnored private weak var extensions: ExtensionManager?
    @ObservationIgnored private var kit: PluginSources?
    @ObservationIgnored private var watcher: FileSystemWatcher?
    @ObservationIgnored let helper = PluginHelperClient(
        executable: PluginHelperClient.bundledExecutable, cacheDirectory: PluginManager.moduleCacheDirectory)

    /// Whether plugin code runs in the helper rather than the app.
    var runsOutOfProcess: Bool {
        helper.isAvailable && ProcessInfo.processInfo.environment["TINYCAST_PLUGINS_IN_PROCESS"] != "1"
    }

    func start(extensions: ExtensionManager) {
        self.extensions = extensions
    }

    // MARK: - The switch

    /// Idempotent both ways. Off means nothing scanned, watched or held, and no command running.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        guard enabled else {
            watcher = nil
            installed = []
            await extensions?.setPlugins([], makeRuntime: nil)
            helper.send(.exitWhenIdle)
            return
        }
        await refresh()
        watchDirectory()
        warmKit()
    }

    func refresh() async {
        guard isEnabled else { return }
        let found = await scan()
        guard isEnabled, found != installed, let extensions else { return }
        installed = found
        await extensions.setPlugins(hostExtensions(), makeRuntime: makeRuntime(storage: extensions.storage))
    }

    /// Settings' process: the plugins folder as the main app reads it, with nothing run or watched.
    func list(_ enabled: Bool) async {
        let found = enabled ? await scan() : []
        if found != installed { installed = found }
    }

    /// The plugins folder with each manifest run, in the helper when there is one (a manifest is
    /// plugin code too). The helper idles out after a scan that launches nothing.
    private func scan() async -> [InstalledPlugin] {
        if runsOutOfProcess,
            let found = await helper.scan(
                PluginCatalog.pluginsDirectory(), description: PluginCatalog.descriptionDirectory(),
                cache: PluginCatalog.manifestCacheDirectory())
        {
            return found
        }
        return await Self.scanInProcess()
    }

    private static func scanInProcess() async -> [InstalledPlugin] {
        let directory = PluginCatalog.pluginsDirectory()
        let descriptionDirectory = PluginCatalog.descriptionDirectory()
        return await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let description = descriptionDirectory.flatMap {
                try? PluginSources.read(from: $0, requiringMain: false)
            }
            return PluginCatalog.scan(directory, description: description)
        }.value
    }

    /// Each readable plugin as the Extensions host lists it.
    func hostExtensions() -> [InstalledExtension] {
        installed.compactMap { plugin in
            guard case .success(let manifest) = plugin.manifest,
                let host = manifest.extensionManifest()
            else { return nil }
            return InstalledExtension(manifest: host, directory: plugin.directory, engine: .plugin)
        }
    }

    /// The engine the host asks for when one of these commands launches, in any lane.
    private func makeRuntime(storage: ExtensionStorage) -> ExtensionPluginRuntimeFactory {
        { [weak self] owner, hostAPI, _ in
            let plugin = self?.manifest(hostName: owner.manifest.name) ?? .missing(owner.manifest.name)
            if let self, self.runsOutOfProcess {
                return RemotePluginRuntime(
                    client: self.helper, plugin: plugin, directory: owner.directory, storage: storage,
                    hostAPI: hostAPI, appScheme: AppURLScheme.current)
            }
            return ScriftPluginRuntime(
                plugin: plugin,
                directory: owner.directory, storage: storage, hostAPI: hostAPI,
                appScheme: AppURLScheme.current,
                moduleCache: Self.moduleCache, kitSources: { [weak self] in await self?.kitSources() })
        }
    }

    func manifest(hostName: String) -> PluginManifest? {
        for plugin in installed {
            if case .success(let manifest) = plugin.manifest, manifest.hostName == hostName { return manifest }
        }
        return nil
    }

    /// Hot reload: any change under the plugins folder rescans it (an unchanged manifest is a cache
    /// lookup), and a command running from a plugin whose files changed starts again from the new
    /// code, so an author sees an edit about a second after saving it.
    private func watchDirectory() {
        let directory = PluginCatalog.pluginsDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.resolvingSymlinksInPath().path
        watcher = FileSystemWatcher(
            paths: [root], since: FSEventStreamEventId(kFSEventStreamEventIdSinceNow), queue: .main
        ) { [weak self] events in
            let folders = Set(events.compactMap { Self.pluginFolder(of: $0.path, in: root) })
            Task { @MainActor in await self?.pluginsChanged(folders) }
        }
    }

    /// The plugin folder's name a changed path is in, or nil for the plugins folder itself.
    nonisolated static func pluginFolder(of path: String, in root: String) -> String? {
        guard path.hasPrefix(root + "/") else { return nil }
        return path.dropFirst(root.count + 1).split(separator: "/").first.map(String.init)
    }

    private func pluginsChanged(_ folders: Set<String>) async {
        guard isEnabled else { return }
        await refresh()
        for folder in folders {
            guard let plugin = installed.first(where: { $0.directory.lastPathComponent == folder }),
                case .success(let manifest) = plugin.manifest
            else { continue }
            await extensions?.relaunch(extension: manifest.hostName)
        }
    }

    /// Compiled kits and plugins, kept in the caches folder so a module compiles once per source
    /// and Scrift version, not once per app launch.
    static let moduleCache = ScriftModuleCache(capacity: moduleCapacity, directory: moduleCacheDirectory)

    /// Compiled modules kept in memory besides those running: the kit and a few plugins. More is
    /// memory the app holds for launches the disk cache answers in milliseconds anyway.
    static let moduleCapacity = 6

    static var moduleCacheDirectory: URL {
        AppPaths.caches().appending(path: "ScriftModules", directoryHint: .isDirectory)
    }

    /// Compiling the kit is most of a first launch; doing it once now leaves a launch ~15 ms. In
    /// the helper, which the startup scan has just started, it compiles into the shared disk cache
    /// the first time after an update and is a lookup from then on.
    private func warmKit() {
        if runsOutOfProcess {
            if let kit = PluginCatalog.kitDirectory() { helper.send(.warm(kitDirectory: kit.path)) }
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.isEnabled, let kit = await self.kitSources() else { return }
            let context = ScriftContext(
                modules: PluginCapabilities.modules(for: []), cache: Self.moduleCache, output: { _ in })
            // Compiled off the main actor (Scrift's async load).
            _ = try? await context.load(
                files: kit.files.map { SourceFile(name: $0.name, text: $0.text) }, moduleName: "Tinycast")
        }
    }

    private func kitSources() async -> PluginSources? {
        if let kit { return kit }
        guard let directory = PluginCatalog.kitDirectory() else { return nil }
        let read = await Task.detached(priority: .userInitiated) {
            try? PluginSources.read(from: directory, requiringMain: false)
        }.value
        kit = read
        return read
    }
}

extension PluginManifest {
    /// What a runtime made for a plugin that vanished mid-launch reports: no commands to run.
    static func missing(_ hostName: String) -> PluginManifest {
        PluginManifest(
            name: String(hostName.dropFirst(hostNamePrefix.count)), title: hostName, description: nil,
            icon: nil, author: nil, permissions: [], urlSchemes: [], preferences: [], commands: [])
    }
}
