import Foundation

/// A plugin folder as the catalog found it: a manifest Tinycast can list, or why it can't.
struct InstalledPlugin: Sendable, Hashable, Identifiable {
    let directory: URL
    let manifest: Result<PluginManifest, PluginManifestError>

    /// The folder's name until the manifest is readable, so a broken plugin still has a row.
    var id: String { (try? manifest.get().name) ?? directory.lastPathComponent }
    var title: String { (try? manifest.get().title) ?? directory.lastPathComponent }
    var commands: [PluginCommand] { (try? manifest.get().commands) ?? [] }

    static func entryID(plugin: String, command: String) -> String {
        "plugin." + plugin + "." + command
    }

    /// The Swift module the plugin's files compile into: `world-clock` is `WorldClock`.
    static func moduleName(for name: String) -> String {
        let words = name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let joined = words.joined()
        let reserved: Set<String> = ["Tinycast", "Foundation", "AppKit", "Swift"]
        guard let first = joined.first, !first.isNumber, !reserved.contains(joined) else {
            return "Plugin" + joined
        }
        return joined
    }
}

/// A plugin's Swift files, read for one launch.
struct PluginSources: Sendable {
    struct File: Sendable {
        let name: String
        let text: String
    }

    let files: [File]

    /// Bounds the read, since a plugin folder is someone else's: a few hundred files is plenty.
    static let maximumFiles = 256

    enum ReadError: Error, CustomStringConvertible {
        case noMain
        case tooManyFiles
        case unreadable(String)

        var description: String {
            switch self {
            case .noMain: "the plugin has no main.swift, which registers its commands"
            case .tooManyFiles: "the plugin has more than \(PluginSources.maximumFiles) Swift files"
            case .unreadable(let name): "\(name) can't be read as UTF-8 text"
            }
        }
    }

    /// Every `.swift` file under the folder, by path relative to it, in a stable order; the
    /// folder's own `Manifest.swift` isn't one, since it runs on its own before them.
    static func read(
        from directory: URL, requiringMain: Bool = true, fileManager: FileManager = .default
    ) throws(ReadError) -> PluginSources {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard
            let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return PluginSources(files: []) }
        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            if url.lastPathComponent == PluginManifestReader.fileName,
                url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == root.path
            {
                continue
            }
            urls.append(url)
            if urls.count > maximumFiles { throw .tooManyFiles }
        }
        var files: [File] = []
        for url in urls {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            // A symlink out of the folder would let a plugin read another file as its source.
            guard resolved.path.hasPrefix(root.path + "/") else { continue }
            let name = String(resolved.path.dropFirst(root.path.count + 1))
            guard let text = try? String(contentsOf: resolved, encoding: .utf8) else {
                throw .unreadable(name)
            }
            files.append(File(name: name, text: text))
        }
        files.sort { $0.name < $1.name }
        guard !requiringMain || files.contains(where: { $0.name == "main.swift" }) else {
            throw .noMain
        }
        return PluginSources(files: files)
    }
}
