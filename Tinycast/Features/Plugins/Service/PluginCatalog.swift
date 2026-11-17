import Foundation

/// Where plugins live on disk, and what is there.
enum PluginCatalog {
    /// One folder per plugin, each with a `plugin.json` and its Swift files.
    static func pluginsDirectory() -> URL {
        AppPaths.applicationSupport().appending(path: "Plugins", directoryHint: .isDirectory)
    }

    /// A plugin's `@AppStorage`, outside its folder so replacing the folder keeps it.
    static func storageFile(for plugin: String) -> URL {
        AppPaths.applicationSupport()
            .appending(path: "PluginData", directoryHint: .isDirectory)
            .appending(path: plugin + ".json", directoryHint: .notDirectory)
    }

    /// The kit plugins import as `Tinycast`, shipped as Swift source in the app bundle.
    static func kitDirectory(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "PluginKit", withExtension: nil)
    }

    /// File IO: callers run it off the main actor.
    nonisolated static func scan(
        _ directory: URL = pluginsDirectory(), fileManager: FileManager = .default
    ) -> [InstalledPlugin] {
        guard
            let folders = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        var plugins: [InstalledPlugin] = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let manifestURL = folder.appending(path: "plugin.json", directoryHint: .notDirectory)
            guard fileManager.fileExists(atPath: manifestURL.path) else { continue }
            let manifest: Result<PluginManifest, PluginManifestError>
            do {
                let data = try Data(contentsOf: manifestURL)
                manifest = .success(try PluginManifest.decode(data))
            } catch let error as PluginManifestError {
                manifest = .failure(error)
            } catch {
                manifest = .failure(.unreadable(error.localizedDescription))
            }
            plugins.append(InstalledPlugin(directory: folder, manifest: manifest))
        }
        // Two folders claiming one name would share storage and launcher entries; the first wins.
        var names: Set<String> = []
        return plugins.filter { names.insert($0.id).inserted }
    }
}
