import Foundation

/// Owns the installed plugins and hands their commands to the Extensions host, which runs them in
/// its palette, background and menu-bar lanes with `WasmPluginRuntime` as their engine.
@MainActor
@Observable
final class PluginManager {
    private(set) var isEnabled = false
    /// Every plugin folder, a manifest that failed to read included, as Settings lists them.
    private(set) var installed: [InstalledPlugin] = []

    @ObservationIgnored private var modules: [String: PluginModule] = [:]
    @ObservationIgnored private weak var extensions: ExtensionManager?
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
            modules = [:]
            await extensions?.setPlugins([], makeRuntime: nil)
            return
        }
        await refresh()
        watchDirectory()
    }

    /// Rescans the folder; a changed `plugin.wasm` is metered and described again, an unchanged
    /// one comes from the cache.
    func refresh() async {
        guard isEnabled else { return }
        let directory = PluginCatalog.pluginsDirectory()
        let found = await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return PluginCatalog.scan(directory)
        }.value
        let plugins = found.map(\.plugin)
        guard isEnabled, plugins != installed || modules.count != found.count(where: { $0.module != nil }),
            let extensions
        else { return }
        installed = plugins
        modules = [:]
        for module in found.compactMap(\.module) { modules[module.manifest.hostName] = module }
        await extensions.setPlugins(hostExtensions(), makeRuntime: makeRuntime())
    }

    /// Each readable plugin as the Extensions host lists it.
    private func hostExtensions() -> [InstalledExtension] {
        installed.compactMap { plugin in
            guard case .success(let manifest) = plugin.manifest, let host = manifest.extensionManifest()
            else {
                return nil
            }
            return InstalledExtension(manifest: host, directory: plugin.directory, engine: .plugin)
        }
    }

    /// The engine the host asks for when one of these commands launches, in any lane.
    private func makeRuntime() -> ExtensionPluginRuntimeFactory {
        { [weak self] owner, hostAPI, priority in
            let module =
                self?.modules[owner.manifest.name]
                ?? PluginModule(manifest: .missing(owner.manifest.name), meteredURL: owner.directory)
            return WasmPluginRuntime(
                module: module, hostAPI: hostAPI, appScheme: AppURLScheme.current, priority: priority)
        }
    }

    func manifest(hostName: String) -> PluginManifest? { modules[hostName]?.manifest }

    /// A folder added, removed or replaced rescans. Rebuilding a plugin in place replaces its
    /// `plugin.wasm` inside the folder, which this doesn't see: Settings › Plugins › Reload does.
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
}

extension PluginManifest {
    /// What a runtime made for a plugin that vanished mid-launch reports: no commands to run.
    static func missing(_ hostName: String) -> PluginManifest {
        PluginManifest(
            name: String(hostName.dropFirst(hostNamePrefix.count)), title: hostName, description: nil,
            icon: nil, author: nil, permissions: [], urlSchemes: [], preferences: [], commands: [])
    }
}
