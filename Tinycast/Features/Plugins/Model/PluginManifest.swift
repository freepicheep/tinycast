import Foundation

/// What a plugin's `Manifest.swift` declares: everything Tinycast lists before any of the plugin's
/// code runs. `PluginManifestReader` runs the manifest; its JSON form is what this type decodes and
/// what `tinycast-plugin dump` prints.
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
    /// Settings every command reads, which the user sets in Settings › Plugins.
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

    /// What the command reads before the user sets it.
    var defaultValue: PluginValue? {
        if type == "checkbox" { return .bool(defaultFlag ?? false) }
        return defaultText.map(PluginValue.string)
    }
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
    /// `URLSession.shared` in `import Foundation`.
    case network
    /// `NSPasteboard.general.string(forType:)` in `import AppKit`; copying never needs this.
    case clipboard
    /// `selectedText()` and `selectedFinderItems()` in `import Selection`.
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
    /// How a command runs, by the `Plugin` call that registers it.
    enum Mode: String, Sendable, Hashable, Codable {
        /// Opens a screen in the palette, registered with `Plugin.command`.
        case view
        /// Runs and closes the palette, registered with `Plugin.action`.
        case action
        /// A menu in the menu bar, registered with `Plugin.menuBar`.
        case menuBar
    }

    let name: String
    let title: String
    let subtitle: String?
    let description: String?
    let icon: String?
    let mode: Mode
    let keywords: [String]
    /// Seconds between background runs, or menu-bar refreshes.
    let interval: TimeInterval?
    let arguments: [PluginArgument]
    let preferences: [PluginPreference]
    let disabledByDefault: Bool

    var id: String { name }
}

enum PluginManifestError: Error, Hashable, CustomStringConvertible, Codable {
    case unreadable(String)
    /// Scrift's diagnostics, each with its line in `Manifest.swift`.
    case compile(String)
    case panic(String)
    case noPlugin
    case severalPlugins(Int)
    case descriptionMissing
    case invalidName(String)
    case noCommands
    case duplicateCommand(String)
    case unknownPermission(String)
    case invalidURLScheme(String)
    case invalidPreference(String)
    case invalidInterval(Double)

    var description: String {
        switch self {
        case .unreadable(let reason): "Manifest.swift can't be read: \(reason)"
        case .compile(let diagnostics): diagnostics
        case .panic(let panic): "Manifest.swift stopped: \(panic)"
        case .noPlugin: "Manifest.swift creates no Plugin: add let plugin = Plugin(…)"
        case .severalPlugins(let count): "Manifest.swift creates \(count) Plugins; a plugin has one"
        case .descriptionMissing: "The plugin description is missing from the app bundle."
        case .invalidName(let name):
            "“\(name)” isn't a valid name; use lowercase letters, digits and hyphens"
        case .noCommands: "Manifest.swift declares no commands"
        case .duplicateCommand(let name): "the command “\(name)” is declared twice"
        case .unknownPermission(let name): "“\(name)” isn't a permission Tinycast grants"
        case .invalidURLScheme(let scheme): "“\(scheme)” isn't a URL scheme a plugin may open"
        case .invalidPreference(let name): "the preference “\(name)” is declared twice or has no type"
        case .invalidInterval(let seconds):
            "an interval of \(seconds) seconds can't be: write one more than zero, such as .minutes(10)"
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
            if let interval = command.interval, !(interval.isFinite && interval > 0) {
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
        let interval: TimeInterval?
        let arguments: [PluginArgument]?
        let preferences: [PluginPreference]?
        let disabledByDefault: Bool?
    }
}
