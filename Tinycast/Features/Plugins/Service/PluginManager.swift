import Foundation
import Stir

/// Owns the installed plugins and hands their commands to the Extensions host, which runs them in
/// its palette, background and menu-bar lanes with `StirPluginRuntime` as their engine.
@MainActor
@Observable
final class PluginManager {
    private(set) var isEnabled = false
    /// Every plugin folder, a manifest that failed to read included, as Settings lists them.
    private(set) var installed: [InstalledPlugin] = []

    @ObservationIgnored private weak var extensions: ExtensionManager?
    @ObservationIgnored private var kit: PluginSources?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?

    func start(extensions: ExtensionManager) {
        self.extensions = extensions
    }

    // MARK: - The switch

    /// Idempotent both ways. Off means nothing scanned, watched or held, and no command running.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        guard enabled else {
            watcher?.cancel()
            watcher = nil
            installed = []
            await extensions?.setPlugins([], makeRuntime: nil)
            return
        }
        await refresh()
        watchDirectory()
        warmKit()
    }

    func refresh() async {
        guard isEnabled else { return }
        let directory = PluginCatalog.pluginsDirectory()
        let descriptionDirectory = PluginCatalog.descriptionDirectory()
        let found = await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let description = descriptionDirectory.flatMap {
                try? PluginSources.read(from: $0, requiringMain: false)
            }
            return PluginCatalog.scan(directory, description: description)
        }.value
        guard isEnabled, found != installed, let extensions else { return }
        installed = found
        await extensions.setPlugins(hostExtensions(), makeRuntime: makeRuntime(storage: extensions.storage))
    }

    /// Each readable plugin as the Extensions host lists it.
    private func hostExtensions() -> [InstalledExtension] {
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
            StirPluginRuntime(
                plugin: self?.manifest(hostName: owner.manifest.name) ?? .missing(owner.manifest.name),
                directory: owner.directory, storage: storage, hostAPI: hostAPI,
                kitSources: { [weak self] in await self?.kitSources() })
        }
    }

    func manifest(hostName: String) -> PluginManifest? {
        for plugin in installed {
            if case .success(let manifest) = plugin.manifest, manifest.hostName == hostName { return manifest }
        }
        return nil
    }

    /// Adding or removing a plugin folder rescans; a plugin's code is read fresh on every launch.
    /// An edited `Manifest.swift` is listed after Settings → Plugins → Reload, or a relaunch.
    private func watchDirectory() {
        let directory = PluginCatalog.pluginsDirectory()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    /// Compiling the kit is most of a first launch; doing it once now leaves a launch ~15 ms.
    private func warmKit() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.isEnabled, let kit = await self.kitSources() else { return }
            let context = StirContext(modules: PluginCapabilities.modules(for: []), output: { _ in })
            _ = try? context.load(
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
