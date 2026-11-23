import Foundation

/// Where plugins live on disk, and what is there.
enum PluginCatalog {
    /// One folder per plugin, each with a `Manifest.swift`, a `main.swift` and any other Swift files.
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

    /// The module plugins' `Manifest.swift` imports, shipped as Swift source in the app bundle.
    static func descriptionDirectory(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: PluginManifestReader.descriptionModule, withExtension: nil)
    }

    /// What each manifest declared, by its text's hash; see `PluginManifestReader.read`.
    static func manifestCacheDirectory() -> URL {
        AppPaths.applicationSupport().appending(path: "PluginManifests", directoryHint: .isDirectory)
    }

    /// File IO and every changed manifest's run: callers run it off the main actor.
    /// - Parameters:
    ///   - description: The module manifests import; every plugin fails to list without it.
    ///   - cache: Where manifests' results are kept; entries no plugin used any more are removed.
    nonisolated static func scan(
        _ directory: URL = pluginsDirectory(), description: PluginSources?,
        cache: URL? = manifestCacheDirectory(), fileManager: FileManager = .default
    ) -> [InstalledPlugin] {
        guard
            let folders = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        var plugins: [InstalledPlugin] = []
        var cacheEntries: Set<String> = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let manifestURL = folder.appending(path: PluginManifestReader.fileName, directoryHint: .notDirectory)
            guard fileManager.fileExists(atPath: manifestURL.path) else { continue }
            let manifest: Result<PluginManifest, PluginManifestError>
            if let description {
                if let source = try? String(contentsOf: manifestURL, encoding: .utf8) {
                    let read = PluginManifestReader.read(source, description: description, cache: cache)
                    manifest = read.manifest
                    cacheEntries.insert(read.cacheEntry)
                } else {
                    manifest = .failure(.unreadable("it isn't UTF-8 text"))
                }
            } else {
                manifest = .failure(.descriptionMissing)
            }
            plugins.append(InstalledPlugin(directory: folder, manifest: manifest))
        }
        if let cache, description != nil,
            let entries = try? fileManager.contentsOfDirectory(atPath: cache.path)
        {
            for entry in entries where !cacheEntries.contains(entry) {
                try? fileManager.removeItem(at: cache.appending(path: entry, directoryHint: .notDirectory))
            }
        }
        // Two folders claiming one name would share storage and launcher entries; the first wins.
        var names: Set<String> = []
        return plugins.filter { names.insert($0.id).inserted }
    }
}
