import Foundation

/// A plugin folder as the catalog found it: a manifest Tinycast can list, or why it can't.
struct InstalledPlugin: Sendable, Hashable, Identifiable {
    /// The module a plugin folder holds; everything else in the folder is its own business.
    static let moduleFileName = "plugin.wasm"

    let directory: URL
    let manifest: Result<PluginManifest, PluginManifestError>

    /// The folder's name until the manifest is readable, so a broken plugin still has a row.
    var id: String { (try? manifest.get().name) ?? directory.lastPathComponent }
    var title: String { (try? manifest.get().title) ?? directory.lastPathComponent }
    var commands: [PluginCommand] { (try? manifest.get().commands) ?? [] }
    var moduleURL: URL { directory.appending(path: Self.moduleFileName, directoryHint: .notDirectory) }
}
