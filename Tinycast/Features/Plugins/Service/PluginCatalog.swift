import CryptoKit
import Foundation

/// Where plugins live on disk, and what is there.
enum PluginCatalog {
    /// One folder per plugin, each named after it and holding its `plugin.wasm`.
    static func pluginsDirectory() -> URL {
        AppPaths.applicationSupport().appending(path: "Plugins", directoryHint: .isDirectory)
    }

    /// Each module metered and described, by the original's hash; rebuilt from the plugins at will.
    static func cacheDirectory() -> URL {
        AppPaths.caches().appending(path: "Plugins", directoryHint: .isDirectory)
    }

    /// A plugin's memory may grow to 512 MiB, in WebAssembly's 64 KiB pages.
    static let memoryCap: UInt64 = 8192

    /// Bumped when `WasmMeter`'s output changes, so no module metered the old way is kept.
    static let meterVersion = 1

    struct Found: Sendable, Equatable {
        let plugin: InstalledPlugin
        /// Nil when the manifest couldn't be read.
        let module: PluginModule?
    }

    /// File IO, metering and describing every changed module: callers run it off the main actor.
    /// Cache entries no plugin uses any more are removed.
    nonisolated static func scan(
        _ directory: URL = pluginsDirectory(), cache: URL = cacheDirectory(),
        fileManager: FileManager = .default
    ) -> [Found] {
        guard
            let folders = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        try? fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        var found: [Found] = []
        var kept: Set<String> = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            let moduleURL = folder.appending(
                path: InstalledPlugin.moduleFileName, directoryHint: .notDirectory)
            guard let original = try? Data(contentsOf: moduleURL, options: .alwaysMapped) else { continue }
            let key =
                "\(meterVersion)-" + SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
            kept.insert(key + ".wasm")
            kept.insert(key + ".json")
            let entry = load(original, key: key, cache: cache)
            let manifest = entry.flatMap { manifest -> Result<PluginManifest, PluginManifestError> in
                manifest.name == folder.lastPathComponent
                    ? .success(manifest)
                    : .failure(.folderMismatch(folder: folder.lastPathComponent, name: manifest.name))
            }
            let plugin = InstalledPlugin(directory: folder, manifest: manifest)
            let module = (try? manifest.get()).map {
                PluginModule(
                    manifest: $0,
                    meteredURL: cache.appending(path: key + ".wasm", directoryHint: .notDirectory))
            }
            found.append(Found(plugin: plugin, module: module))
        }
        if let entries = try? fileManager.contentsOfDirectory(atPath: cache.path) {
            for entry in entries where !kept.contains(entry) {
                try? fileManager.removeItem(at: cache.appending(path: entry, directoryHint: .notDirectory))
            }
        }
        return found
    }

    /// The cached manifest, or the module metered, written beside it and asked to describe itself.
    private static func load(
        _ original: Data, key: String, cache: URL
    ) -> Result<PluginManifest, PluginManifestError> {
        let meteredURL = cache.appending(path: key + ".wasm", directoryHint: .notDirectory)
        let manifestURL = cache.appending(path: key + ".json", directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: meteredURL.path),
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? PluginManifest.decode(data)
        {
            return .success(manifest)
        }
        let metered: Data
        do {
            metered = Data(try WasmMeter.instrument([UInt8](original), memoryCap: memoryCap))
        } catch {
            return .failure(.module(error.description))
        }
        let manifest = describe(metered)
        if case .success(let value) = manifest {
            try? metered.write(to: meteredURL, options: .atomic)
            try? value.json().write(to: manifestURL, options: .atomic)
        }
        return manifest
    }

    /// Runs the module's `tinycast_describe` with no host APIs: nothing it does here reaches the app.
    nonisolated static func describe(_ metered: Data) -> Result<PluginManifest, PluginManifestError> {
        var json: String?
        var imports = WasmInstance.Imports()
        imports.manifest = { json = $0 }
        do {
            let instance = try WasmInstance(module: metered, imports: imports)
            try instance.call("tinycast_describe")
        } catch {
            return .failure(.module(error.description))
        }
        guard let json, json != "{}", let data = json.data(using: .utf8) else { return .failure(.noManifest) }
        return Result { () throws(PluginManifestError) in try PluginManifest.decode(data) }
    }
}
