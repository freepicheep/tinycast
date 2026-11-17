import CryptoKit
import Foundation
import Stir
import StirFoundation

/// Runs a plugin's `Manifest.swift` and reads back the plugin it declares.
///
/// The manifest runs on its own, before any of the plugin's code: in a context of its own with
/// Foundation's slice and the description it imports, no host API, none of the permissions it
/// declares, and a command's limits.
enum PluginManifestReader {
    static let fileName = "Manifest.swift"

    /// The module `Manifest.swift` imports, as `PluginSources` from the app bundle's `PluginDescription`.
    static let descriptionModule = "PluginDescription"

    nonisolated static func evaluate(
        _ source: String, description: PluginSources
    ) -> Result<PluginManifest, PluginManifestError> {
        let context = StirContext(modules: [StirFoundation.module], output: { _ in })
        let limits = StirLimits.untrusted
        let json: String
        do {
            let declarations = try context.load(
                files: description.files.map { SourceFile(name: $0.name, text: $0.text) },
                moduleName: descriptionModule)
            try declarations.run(limits: limits)
            let manifest = try context.load(
                files: [SourceFile(name: fileName, text: source)], moduleName: "Manifest")
            try manifest.run(limits: limits)
            let count = try declarations.function("_declaredCount", as: (() throws -> Int).self, limits: limits)()
            guard count > 0 else { return .failure(.noPlugin) }
            guard count == 1 else { return .failure(.severalPlugins(count)) }
            json = try declarations.function("_manifestJSON", as: (() throws -> String).self, limits: limits)()
        } catch let error as StirCompileError {
            return .failure(.compile(error.description))
        } catch let panic as StirPanic {
            return .failure(.panic(panic.description))
        } catch {
            return .failure(.unreadable(String(describing: error)))
        }
        return Result { () throws(PluginManifestError) in try PluginManifest.decode(Data(json.utf8)) }
    }

    /// `evaluate`, remembered in `cache` by the text of the manifest and the description, so a
    /// manifest runs once per edit rather than once per launch. Failures aren't kept: a manifest
    /// that doesn't compile is one its author is editing.
    /// - Returns: The manifest, and the cache entry it used, which a scan keeps.
    nonisolated static func read(
        _ source: String, description: PluginSources, cache: URL?, fileManager: FileManager = .default
    ) -> (manifest: Result<PluginManifest, PluginManifestError>, cacheEntry: String) {
        let entry = cacheKey(source, description: description) + ".json"
        let file = cache?.appending(path: entry, directoryHint: .notDirectory)
        if let file, let data = try? Data(contentsOf: file), let manifest = try? PluginManifest.decode(data) {
            return (.success(manifest), entry)
        }
        let manifest = evaluate(source, description: description)
        if let cache, let file, case .success(let value) = manifest {
            try? fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
            try? value.json().write(to: file, options: .atomic)
        }
        return (manifest, entry)
    }

    nonisolated static func cacheKey(_ source: String, description: PluginSources) -> String {
        var hash = SHA256()
        for file in description.files {
            hash.update(data: Data(file.name.utf8))
            hash.update(data: Data([0]))
            hash.update(data: Data(file.text.utf8))
            hash.update(data: Data([0]))
        }
        hash.update(data: Data(source.utf8))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
