import Foundation

/// What a plugin's module declares: everything Tinycast lists before a command runs. The catalog
/// reads it by calling the module's `tinycast_describe` export with no host APIs; its JSON form is
/// what this type decodes and what `tinycast-plugin describe` prints.
struct PluginManifest: Sendable, Hashable {
    let name: String
    let title: String
    let description: String?
    /// An SF Symbol name.
    let icon: String?
    let author: String?
    let permissions: Set<PluginPermission>
    /// App link schemes the plugin may open, such as `cleanshot`; web, mail and files need none.
    let urlSchemes: Set<String>
    /// Settings every command reads, in the shape Raycast's `package.json` gives them.
    let preferences: [PluginPreference]
    let commands: [PluginCommand]
}

/// A setting the user fills in Settings › Plugins, declared with `Plugin.Preference`.
struct PluginPreference: Sendable, Hashable, Codable {
    struct Option: Sendable, Hashable, Codable {
        let title: String
        let value: String
    }

    let name: String
    /// `textfield`, `password`, `checkbox`, `dropdown`, `appPicker`, `file` or `directory`.
    let type: String
    let title: String
    let label: String?
    let description: String?
    let placeholder: String?
    let required: Bool?
    let defaultText: String?
    let defaultFlag: Bool?
    let data: [Option]?

    static let kinds: Set<String> = [
        "textfield", "password", "checkbox", "dropdown", "appPicker", "file", "directory"
    ]
}

/// A field the launcher collects before a command runs, declared with `Plugin.Argument`.
struct PluginArgument: Sendable, Hashable, Codable {
    let name: String
    /// `text` or `password`.
    let type: String
    let placeholder: String
    let required: Bool?
}

/// What a plugin may reach beyond its own palette screen; each grants scripts an API.
enum PluginPermission: String, Sendable, Hashable, CaseIterable, Codable {
    /// `fetch`, WebSockets and name lookups.
    case network
    /// Reading the clipboard; copying and pasting never need this.
    case clipboard
    /// The frontmost app's selected text, and Finder's selected files.
    case selection

    var title: String {
        switch self {
        case .network: String(localized: "Network")
        case .clipboard: String(localized: "Read the Clipboard")
        case .selection: String(localized: "Read the Selection")
        }
    }
}

struct PluginCommand: Sendable, Hashable, Identifiable {
    /// Raycast's command modes, spelled as its `package.json` spells them.
    enum Mode: String, Sendable, Hashable, Codable {
        /// Opens a screen in the palette, registered with `Plugin.command`.
        case view
        /// Runs and closes the palette, registered with `Plugin.action`.
        case action = "no-view"
        /// A menu in the menu bar, registered with `Plugin.menuBar`.
        case menuBar = "menu-bar"
    }

    let name: String
    let title: String
    let subtitle: String?
    let description: String?
    let icon: String?
    let mode: Mode
    let keywords: [String]
    /// How often it runs again in the background, as Raycast writes it: `"1m"`, `"12h"`.
    let interval: String?
    let arguments: [PluginArgument]
    let preferences: [PluginPreference]
    let disabledByDefault: Bool

    var id: String { name }
}

enum PluginManifestError: Error, Hashable, CustomStringConvertible {
    case unreadable(String)
    /// The module couldn't be metered, compiled or run far enough to describe itself.
    case module(String)
    case noManifest
    case invalidName(String)
    case folderMismatch(folder: String, name: String)
    case noCommands
    case duplicateCommand(String)
    case unknownPermission(String)
    case invalidURLScheme(String)
    case invalidPreference(String)
    case invalidInterval(String)

    var description: String {
        switch self {
        case .unreadable(let reason): "The manifest can't be read: \(reason)"
        case .module(let reason): "plugin.wasm \(reason)"
        case .noManifest: "plugin.wasm describes no plugin: its @main type must conform to Plugin"
        case .invalidName(let name):
            "“\(name)” isn't a valid name; use lowercase letters, digits and hyphens"
        case .folderMismatch(let folder, let name):
            "the folder “\(folder)” holds the plugin “\(name)”; name the folder after the plugin"
        case .noCommands: "the plugin declares no commands"
        case .duplicateCommand(let name): "the command “\(name)” is declared twice"
        case .unknownPermission(let name): "“\(name)” isn't a permission Tinycast grants"
        case .invalidURLScheme(let scheme): "“\(scheme)” isn't a URL scheme a plugin may open"
        case .invalidPreference(let name): "the preference “\(name)” is declared twice or has no type"
        case .invalidInterval(let interval):
            "“\(interval)” isn't an interval; write a number and s, m, h or d, such as \"10m\""
        }
    }
}

extension PluginManifest {
    /// Strict, so a hand-edited cache entry can't grant what the manifest didn't declare.
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
        var schemes: Set<String> = []
        for scheme in raw.urlSchemes ?? [] {
            guard PluginOpenTarget.isOpenableScheme(scheme) else { throw .invalidURLScheme(scheme) }
            schemes.insert(scheme.lowercased())
        }
        let preferences = raw.preferences ?? []
        try checkPreferences(preferences)
        var seen: Set<String> = []
        var commands: [PluginCommand] = []
        for command in rawCommands {
            guard isValidName(command.name) else { throw .invalidName(command.name) }
            guard seen.insert(command.name).inserted else { throw .duplicateCommand(command.name) }
            let commandPreferences = command.preferences ?? []
            try checkPreferences(preferences + commandPreferences)
            if let interval = command.interval, ExtensionRefreshPolicy.parse(interval, floor: 0) == nil {
                throw .invalidInterval(interval)
            }
            commands.append(
                PluginCommand(
                    name: command.name, title: command.title, subtitle: command.subtitle,
                    description: command.description, icon: command.icon, mode: command.mode ?? .view,
                    keywords: command.keywords ?? [], interval: command.interval,
                    arguments: command.arguments ?? [], preferences: commandPreferences,
                    disabledByDefault: command.disabledByDefault ?? false))
        }
        return PluginManifest(
            name: raw.name, title: raw.title, description: raw.description, icon: raw.icon,
            author: raw.author, permissions: permissions, urlSchemes: schemes, preferences: preferences,
            commands: commands)
    }

    private static func checkPreferences(_ preferences: [PluginPreference]) throws(PluginManifestError) {
        var names: Set<String> = []
        for preference in preferences {
            guard names.insert(preference.name).inserted, PluginPreference.kinds.contains(preference.type)
            else { throw .invalidPreference(preference.name) }
        }
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

    /// Pretty and with sorted keys, so the same manifest always prints the same bytes.
    func json() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let raw = RawManifest(
            name: name, title: title, description: description, icon: icon, author: author,
            permissions: permissions.isEmpty ? nil : permissions.map(\.rawValue).sorted(),
            urlSchemes: urlSchemes.isEmpty ? nil : urlSchemes.sorted(),
            preferences: preferences.isEmpty ? nil : preferences,
            commands: commands.map {
                RawCommand(
                    name: $0.name, title: $0.title, subtitle: $0.subtitle, description: $0.description,
                    icon: $0.icon, mode: $0.mode, keywords: $0.keywords.isEmpty ? nil : $0.keywords,
                    interval: $0.interval, arguments: $0.arguments.isEmpty ? nil : $0.arguments,
                    preferences: $0.preferences.isEmpty ? nil : $0.preferences,
                    disabledByDefault: $0.disabledByDefault ? true : nil)
            })
        // Strings, optionals and arrays of them can't fail to encode.
        return (try? encoder.encode(raw)) ?? Data()
    }

    private struct RawManifest: Codable {
        let name: String
        let title: String
        let description: String?
        let icon: String?
        let author: String?
        let permissions: [String]?
        let urlSchemes: [String]?
        let preferences: [PluginPreference]?
        let commands: [RawCommand]?
    }

    private struct RawCommand: Codable {
        let name: String
        let title: String
        let subtitle: String?
        let description: String?
        let icon: String?
        let mode: PluginCommand.Mode?
        let keywords: [String]?
        let interval: String?
        let arguments: [PluginArgument]?
        let preferences: [PluginPreference]?
        let disabledByDefault: Bool?
    }
}

// MARK: - In the Extensions host

extension PluginManifest {
    /// The prefix that keeps a plugin's name apart from every Raycast extension's: their names
    /// can't hold a dot, so `plugin.hacker-news` is never one of them.
    static let hostNamePrefix = ExtensionEngine.pluginNamePrefix

    var hostName: String { Self.hostNamePrefix + name }

    /// The manifest as the Extensions host reads a `package.json`, so the palette, menu bar,
    /// background refresh, arguments and preferences treat a plugin's commands as their own.
    func extensionManifest() -> ExtensionManifest? {
        func preference(_ preference: PluginPreference) -> [String: Any] {
            var json: [String: Any] = ["name": preference.name, "type": preference.type, "title": preference.title]
            json["label"] = preference.label
            json["description"] = preference.description
            json["placeholder"] = preference.placeholder
            json["required"] = preference.required
            if let text = preference.defaultText {
                json["default"] = text
            } else if let flag = preference.defaultFlag {
                json["default"] = flag
            }
            json["data"] = preference.data?.map { ["title": $0.title, "value": $0.value] }
            return json
        }
        var json: [String: Any] = [
            "name": hostName, "title": title, "description": description ?? "", "author": author ?? "",
            "preferences": preferences.map(preference),
            "commands": commands.map { command -> [String: Any] in
                var entry: [String: Any] = [
                    "name": command.name, "title": command.title, "mode": command.mode.rawValue,
                    "keywords": command.keywords, "description": command.description ?? "",
                    "preferences": command.preferences.map(preference),
                    "arguments": command.arguments.map { argument -> [String: Any] in
                        ["name": argument.name, "type": argument.type, "placeholder": argument.placeholder,
                         "required": argument.required ?? false]
                    },
                    "disabledByDefault": command.disabledByDefault
                ]
                entry["subtitle"] = command.subtitle ?? title
                entry["icon"] = command.icon
                entry["interval"] = command.interval
                return entry
            }
        ]
        json["icon"] = icon
        return ExtensionManifest(json: json)
    }
}
