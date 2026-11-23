import Foundation

// What a plugin's `Manifest.swift` imports: `import PluginDescription`. Scrift runs the manifest on its own,
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
        /// `selectedText()` and `selectedFinderItems()` in `import Selection`: what the user selected
        /// in the app in front, or in Finder.
        case selection
        /// App links with these schemes, such as `cleanshot`. Web, mail and file links need none.
        case openURLs(schemes: [String])
    }

    /// One launcher row; `main.swift` gives each its code by name.
    public struct Command {
        let name: String
        let title: String
        let subtitle: String?
        let description: String?
        let icon: String?
        let mode: String
        let keywords: [String]
        let interval: String?
        let arguments: [Argument]
        let preferences: [Preference]
        let disabledByDefault: Bool

        /// A command that opens a screen in the palette, registered with `Plugin.command(name)`.
        /// - Parameters:
        ///   - name: Lowercase letters, digits and hyphens, unique in the plugin.
        ///   - subtitle: Shown beside the title; the plugin's title when nil.
        ///   - icon: An SF Symbol name; the plugin's icon when nil.
        ///   - keywords: More words the launcher matches the command by.
        ///   - arguments: Fields the launcher shows after the title, filled before the command runs.
        ///   - preferences: Settings of this command alone, beside the plugin's own.
        ///   - disabledByDefault: Hidden from the launcher until shown in Settings.
        public static func view(
            _ name: String, title: String, subtitle: String? = nil, description: String? = nil,
            icon: String? = nil, keywords: [String] = [], arguments: [Argument] = [],
            preferences: [Preference] = [], disabledByDefault: Bool = false
        ) -> Command {
            Command(
                name: name, title: title, subtitle: subtitle, description: description, icon: icon,
                mode: "view", keywords: keywords, interval: nil, arguments: arguments,
                preferences: preferences, disabledByDefault: disabledByDefault)
        }

        /// A command that does its work and closes the palette, registered with `Plugin.action(name)`.
        /// - Parameter interval: Runs it again in the background this often once it has run,
        ///   such as `"1m"`, `"12h"` or `"1d"`; a minute at least.
        public static func action(
            _ name: String, title: String, subtitle: String? = nil, description: String? = nil,
            icon: String? = nil, keywords: [String] = [], interval: String? = nil,
            arguments: [Argument] = [], preferences: [Preference] = [], disabledByDefault: Bool = false
        ) -> Command {
            Command(
                name: name, title: title, subtitle: subtitle, description: description, icon: icon,
                mode: "no-view", keywords: keywords, interval: interval, arguments: arguments,
                preferences: preferences, disabledByDefault: disabledByDefault)
        }

        /// A menu in the menu bar, registered with `Plugin.menuBar(name)`.
        /// - Parameter interval: Refreshes it this often while it is shown, ten seconds at least.
        public static func menuBar(
            _ name: String, title: String, subtitle: String? = nil, description: String? = nil,
            icon: String? = nil, keywords: [String] = [], interval: String? = nil,
            preferences: [Preference] = [], disabledByDefault: Bool = false
        ) -> Command {
            Command(
                name: name, title: title, subtitle: subtitle, description: description, icon: icon,
                mode: "menu-bar", keywords: keywords, interval: interval, arguments: [],
                preferences: preferences, disabledByDefault: disabledByDefault)
        }
    }

    /// A field the launcher shows after a command's title; the command reads it as `Plugin.arguments`.
    public struct Argument {
        let name: String
        let kind: String
        let placeholder: String
        let isRequired: Bool

        public static func text(_ name: String, placeholder: String, required: Bool = false) -> Argument {
            Argument(name: name, kind: "text", placeholder: placeholder, isRequired: required)
        }

        public static func password(_ name: String, placeholder: String, required: Bool = false) -> Argument {
            Argument(name: name, kind: "password", placeholder: placeholder, isRequired: required)
        }
    }

    /// A setting the user fills in Settings › Plugins; commands read it with `@Preference`.
    public struct Preference {
        public struct Option {
            let title: String
            let value: String

            public init(_ title: String, value: String) {
                self.title = title
                self.value = value
            }
        }

        let name: String
        let kind: String
        let title: String
        let label: String?
        let description: String?
        let placeholder: String?
        let isRequired: Bool
        let defaultText: String?
        let defaultFlag: Bool?
        let options: [Option]

        /// A line of text.
        public static func textField(
            _ name: String, title: String, description: String? = nil, placeholder: String? = nil,
            default value: String? = nil, required: Bool = false
        ) -> Preference {
            Preference(
                name: name, kind: "textfield", title: title, label: nil, description: description,
                placeholder: placeholder, isRequired: required, defaultText: value, defaultFlag: nil,
                options: [])
        }

        /// Text that is never shown, such as an API key.
        public static func password(
            _ name: String, title: String, description: String? = nil, placeholder: String? = nil,
            required: Bool = false
        ) -> Preference {
            Preference(
                name: name, kind: "password", title: title, label: nil, description: description,
                placeholder: placeholder, isRequired: required, defaultText: nil, defaultFlag: nil,
                options: [])
        }

        /// A switch; `label` is the text beside it.
        public static func checkbox(
            _ name: String, title: String, label: String, description: String? = nil,
            default value: Bool = false
        ) -> Preference {
            Preference(
                name: name, kind: "checkbox", title: title, label: label, description: description,
                placeholder: nil, isRequired: false, defaultText: nil, defaultFlag: value, options: [])
        }

        /// One of `options`, by value.
        public static func dropdown(
            _ name: String, title: String, options: [Option], description: String? = nil,
            default value: String? = nil, required: Bool = false
        ) -> Preference {
            Preference(
                name: name, kind: "dropdown", title: title, label: nil, description: description,
                placeholder: nil, isRequired: required, defaultText: value, defaultFlag: nil,
                options: options)
        }

        /// An application, read as its path.
        public static func application(
            _ name: String, title: String, description: String? = nil, required: Bool = false
        ) -> Preference {
            Preference(
                name: name, kind: "appPicker", title: title, label: nil, description: description,
                placeholder: nil, isRequired: required, defaultText: nil, defaultFlag: nil, options: [])
        }

        /// A file, read as its path.
        public static func file(
            _ name: String, title: String, description: String? = nil, required: Bool = false
        ) -> Preference {
            Preference(
                name: name, kind: "file", title: title, label: nil, description: description,
                placeholder: nil, isRequired: required, defaultText: nil, defaultFlag: nil, options: [])
        }

        /// A folder, read as its path.
        public static func directory(
            _ name: String, title: String, description: String? = nil, required: Bool = false
        ) -> Preference {
            Preference(
                name: name, kind: "directory", title: title, label: nil, description: description,
                placeholder: nil, isRequired: required, defaultText: nil, defaultFlag: nil, options: [])
        }
    }

    let name: String
    let title: String
    let description: String?
    let icon: String?
    let author: String?
    let permissions: [Permission]
    let preferences: [Preference]
    let commands: [Command]

    /// - Parameters:
    ///   - name: Lowercase letters, digits and hyphens: the plugin's identity, which its storage keeps.
    ///   - icon: An SF Symbol name.
    ///   - preferences: Settings every command of the plugin reads.
    public init(
        name: String, title: String, description: String? = nil, icon: String? = nil, author: String? = nil,
        permissions: [Permission] = [], preferences: [Preference] = [], commands: [Command]
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.icon = icon
        self.author = author
        self.permissions = permissions
        self.preferences = preferences
        self.commands = commands
        _declared.append(self)
    }
}

// MARK: - What Tinycast reads back

var _declared: [Plugin] = []

struct _Option: Encodable {
    let title: String
    let value: String
}

struct _Preference: Encodable {
    let name: String
    let type: String
    let title: String
    let label: String?
    let description: String?
    let placeholder: String?
    let required: Bool?
    let defaultText: String?
    let defaultFlag: Bool?
    let data: [_Option]?
}

struct _Argument: Encodable {
    let name: String
    let type: String
    let placeholder: String
    let required: Bool?
}

struct _Command: Encodable {
    let name: String
    let title: String
    let subtitle: String?
    let description: String?
    let icon: String?
    let mode: String
    let keywords: [String]
    let interval: String?
    let arguments: [_Argument]
    let preferences: [_Preference]
    let disabledByDefault: Bool?
}

struct _Manifest: Encodable {
    let name: String
    let title: String
    let description: String?
    let icon: String?
    let author: String?
    let permissions: [String]
    let urlSchemes: [String]
    let preferences: [_Preference]
    let commands: [_Command]
}

func _declaredCount() -> Int { _declared.count }

func _encode(_ preference: Plugin.Preference) -> _Preference {
    _Preference(
        name: preference.name, type: preference.kind, title: preference.title, label: preference.label,
        description: preference.description, placeholder: preference.placeholder,
        required: preference.isRequired ? true : nil, defaultText: preference.defaultText,
        defaultFlag: preference.defaultFlag,
        data: preference.options.isEmpty
            ? nil : preference.options.map { _Option(title: $0.title, value: $0.value) })
}

/// The one declared plugin, as the JSON Tinycast decodes and checks.
func _manifestJSON() throws -> String {
    let plugin = _declared[0]
    var permissions: [String] = []
    var schemes: [String] = []
    for permission in plugin.permissions {
        switch permission {
        case .network: permissions.append("network")
        case .clipboard: permissions.append("clipboard")
        case .selection: permissions.append("selection")
        case .openURLs(let list): schemes += list
        }
    }
    let manifest = _Manifest(
        name: plugin.name, title: plugin.title, description: plugin.description, icon: plugin.icon,
        author: plugin.author, permissions: permissions, urlSchemes: schemes,
        preferences: plugin.preferences.map { _encode($0) },
        commands: plugin.commands.map { command in
            _Command(
                name: command.name, title: command.title, subtitle: command.subtitle,
                description: command.description, icon: command.icon, mode: command.mode,
                keywords: command.keywords, interval: command.interval,
                arguments: command.arguments.map {
                    _Argument(
                        name: $0.name, type: $0.kind, placeholder: $0.placeholder,
                        required: $0.isRequired ? true : nil)
                },
                preferences: command.preferences.map { _encode($0) },
                disabledByDefault: command.disabledByDefault ? true : nil)
        })
    return String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
}
