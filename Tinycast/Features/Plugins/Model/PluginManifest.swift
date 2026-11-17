import Foundation

/// A plugin's `plugin.json`: everything Tinycast lists before any of the plugin's code runs.
struct PluginManifest: Sendable, Hashable {
    let name: String
    let title: String
    let description: String?
    /// An SF Symbol name.
    let icon: String?
    let author: String?
    let permissions: Set<PluginPermission>
    let commands: [PluginCommand]
}

/// What a plugin may reach beyond its own palette screen; each grants scripts an API.
enum PluginPermission: String, Sendable, Hashable, CaseIterable, Codable {
    /// `URLSession.shared` in `import Foundation`.
    case network
    /// `Pasteboard.string` reads what the user copied; writing on an action never needs this.
    case clipboard

    var title: String {
        switch self {
        case .network: String(localized: "Network")
        case .clipboard: String(localized: "Read the Clipboard")
        }
    }
}

struct PluginCommand: Sendable, Hashable, Identifiable {
    enum Mode: String, Sendable, Hashable, Codable {
        /// Opens a screen in the palette.
        case view
        /// Runs and closes the palette, like a no-view command.
        case action
    }

    let name: String
    let title: String
    let subtitle: String?
    let icon: String?
    let mode: Mode
    let keywords: [String]

    var id: String { name }
}

enum PluginManifestError: Error, Hashable, CustomStringConvertible {
    case unreadable(String)
    case invalidName(String)
    case noCommands
    case duplicateCommand(String)
    case unknownPermission(String)

    var description: String {
        switch self {
        case .unreadable(let reason): "plugin.json can't be read: \(reason)"
        case .invalidName(let name):
            "“\(name)” isn't a valid name; use lowercase letters, digits and hyphens"
        case .noCommands: "plugin.json declares no commands"
        case .duplicateCommand(let name): "the command “\(name)” is declared twice"
        case .unknownPermission(let name): "“\(name)” isn't a permission Tinycast grants"
        }
    }
}

extension PluginManifest {
    /// Strict, so a typo in a permission or mode is an error rather than a silently missing grant.
    static func decode(_ data: Data) throws(PluginManifestError) -> PluginManifest {
        let raw: RawManifest
        do {
            raw = try JSONDecoder().decode(RawManifest.self, from: data)
        } catch {
            throw .unreadable(Self.reason(error))
        }
        guard isValidName(raw.name) else { throw .invalidName(raw.name) }
        guard let rawCommands = raw.commands, !rawCommands.isEmpty else { throw .noCommands }
        var permissions: Set<PluginPermission> = []
        for name in raw.permissions ?? [] {
            guard let permission = PluginPermission(rawValue: name) else {
                throw .unknownPermission(name)
            }
            permissions.insert(permission)
        }
        var seen: Set<String> = []
        var commands: [PluginCommand] = []
        for command in rawCommands {
            guard isValidName(command.name) else { throw .invalidName(command.name) }
            guard seen.insert(command.name).inserted else { throw .duplicateCommand(command.name) }
            commands.append(
                PluginCommand(
                    name: command.name, title: command.title, subtitle: command.subtitle,
                    icon: command.icon, mode: command.mode ?? .view, keywords: command.keywords ?? []))
        }
        return PluginManifest(
            name: raw.name, title: raw.title, description: raw.description, icon: raw.icon,
            author: raw.author, permissions: permissions, commands: commands)
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.first != "-"
            && name.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
            }
    }

    private static func reason(_ error: any Error) -> String {
        switch error as? DecodingError {
        case .keyNotFound(let key, _): "“\(key.stringValue)” is missing"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            context.codingPath.map(\.stringValue).joined(separator: ".") + " has the wrong type"
        case .dataCorrupted(let context): context.debugDescription
        case nil, .some: error.localizedDescription
        }
    }

    private struct RawManifest: Decodable {
        let name: String
        let title: String
        let description: String?
        let icon: String?
        let author: String?
        let permissions: [String]?
        let commands: [RawCommand]?
    }

    private struct RawCommand: Decodable {
        let name: String
        let title: String
        let subtitle: String?
        let icon: String?
        let mode: PluginCommand.Mode?
        let keywords: [String]?
    }
}
