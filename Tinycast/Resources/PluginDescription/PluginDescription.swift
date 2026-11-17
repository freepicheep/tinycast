import Foundation

// What a plugin's `Manifest.swift` imports: `import PluginDescription`. Stir runs the manifest on its own,
// before any of the plugin's code and with none of its permissions, and Tinycast lists what it declares.

/// A plugin: its name, how the launcher shows it, what it may reach and its commands.
///
///     let plugin = Plugin(
///         name: "hacker-news",
///         title: "Hacker News",
///         icon: "newspaper.fill",
///         permissions: [.network],
///         commands: [.view("stories", title: "Hacker News", keywords: ["hn"])]
///     )
public struct Plugin {
    /// What a plugin may reach beyond its own palette screen; each grants scripts an API.
    public enum Permission {
        /// `URLSession.shared` in `import Foundation`.
        case network
        /// `NSPasteboard.general.string(forType:)` in `import AppKit`; copying never needs it.
        case clipboard
        /// App links with these schemes, such as `cleanshot`. Web, mail and file links need none.
        case openURLs(schemes: [String])
    }

    /// One launcher row; `main.swift` gives each its code by name.
    public struct Command {
        let name: String
        let title: String
        let subtitle: String?
        let icon: String?
        let mode: String
        let keywords: [String]

        /// A command that opens a screen in the palette, registered with `Plugin.command(name)`.
        /// - Parameters:
        ///   - name: Lowercase letters, digits and hyphens, unique in the plugin.
        ///   - subtitle: Shown beside the title; the plugin's title when nil.
        ///   - icon: An SF Symbol name; the plugin's icon when nil.
        ///   - keywords: More words the launcher matches the command by.
        public static func view(
            _ name: String, title: String, subtitle: String? = nil, icon: String? = nil, keywords: [String] = []
        ) -> Command {
            Command(name: name, title: title, subtitle: subtitle, icon: icon, mode: "view", keywords: keywords)
        }

        /// A command that does its work and closes the palette, registered with `Plugin.action(name)`.
        public static func action(
            _ name: String, title: String, subtitle: String? = nil, icon: String? = nil, keywords: [String] = []
        ) -> Command {
            Command(name: name, title: title, subtitle: subtitle, icon: icon, mode: "action", keywords: keywords)
        }
    }

    let name: String
    let title: String
    let description: String?
    let icon: String?
    let author: String?
    let permissions: [Permission]
    let commands: [Command]

    /// - Parameters:
    ///   - name: Lowercase letters, digits and hyphens: the plugin's identity, which its storage keeps.
    ///   - icon: An SF Symbol name.
    public init(
        name: String, title: String, description: String? = nil, icon: String? = nil, author: String? = nil,
        permissions: [Permission] = [], commands: [Command]
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.icon = icon
        self.author = author
        self.permissions = permissions
        self.commands = commands
        _declared.append(self)
    }
}

// MARK: - What Tinycast reads back

var _declared: [Plugin] = []

struct _Command: Encodable {
    let name: String
    let title: String
    let subtitle: String?
    let icon: String?
    let mode: String
    let keywords: [String]
}

struct _Manifest: Encodable {
    let name: String
    let title: String
    let description: String?
    let icon: String?
    let author: String?
    let permissions: [String]
    let urlSchemes: [String]
    let commands: [_Command]
}

func _declaredCount() -> Int { _declared.count }

/// The one declared plugin, as the JSON Tinycast decodes and checks.
func _manifestJSON() throws -> String {
    let plugin = _declared[0]
    var permissions: [String] = []
    var schemes: [String] = []
    for permission in plugin.permissions {
        switch permission {
        case .network: permissions.append("network")
        case .clipboard: permissions.append("clipboard")
        case .openURLs(let list): schemes += list
        }
    }
    let manifest = _Manifest(
        name: plugin.name, title: plugin.title, description: plugin.description, icon: plugin.icon,
        author: plugin.author, permissions: permissions, urlSchemes: schemes,
        commands: plugin.commands.map {
            _Command(
                name: $0.name, title: $0.title, subtitle: $0.subtitle, icon: $0.icon, mode: $0.mode,
                keywords: $0.keywords)
        })
    return String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
}
