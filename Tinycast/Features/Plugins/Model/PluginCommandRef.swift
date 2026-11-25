import Foundation

/// One plugin command, by the plugin's name and the command's: what the launcher, hot keys and
/// settings key it by.
struct PluginCommandRef: Codable, Sendable, Hashable {
    let plugin: String
    let command: String

    static let entryPrefix = "plugin:"

    /// The `AppEntry.id` the command is listed under.
    var entryID: String { "\(Self.entryPrefix)\(plugin)/\(command)" }

    init(plugin: String, command: String) {
        self.plugin = plugin
        self.command = command
    }

    init?(entryID: String) {
        guard entryID.hasPrefix(Self.entryPrefix) else { return nil }
        let body = entryID.dropFirst(Self.entryPrefix.count)
        guard let slash = body.firstIndex(of: "/") else { return nil }
        plugin = String(body[body.startIndex..<slash])
        command = String(body[body.index(after: slash)...])
        guard !plugin.isEmpty, !command.isEmpty else { return nil }
    }
}

extension InstalledPlugin {
    /// Entry IDs of commands that are gone: a folder removed, or a command its manifest dropped. A
    /// manifest that stops compiling removes nothing, so a typo doesn't cost a shortcut.
    static func removedCommands(from old: [InstalledPlugin], to new: [InstalledPlugin]) -> [String] {
        let present = Set(new.map(\.id))
        let readable = Dictionary(
            new.compactMap { plugin in (try? plugin.manifest.get()).map { ($0.name, Set($0.commands.map(\.name))) } },
            uniquingKeysWith: { first, _ in first })
        var removed: [String] = []
        for plugin in old {
            guard case .success(let manifest) = plugin.manifest else { continue }
            for command in manifest.commands {
                let gone =
                    !present.contains(manifest.name)
                    || readable[manifest.name].map { !$0.contains(command.name) } ?? false
                if gone { removed.append(PluginCommandRef(plugin: manifest.name, command: command.name).entryID) }
            }
        }
        return removed
    }
}
