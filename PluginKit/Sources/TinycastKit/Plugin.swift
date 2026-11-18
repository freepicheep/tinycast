// What a plugin declares, and what every command can ask of Tinycast.

/// A plugin: its manifest, and its commands with their code. Mark it `@main`.
///
///     @main
///     struct WorldClock: Plugin {
///         let manifest = Manifest(name: "world-clock", title: "World Clock", icon: "globe")
///
///         var commands: [Command] {
///             Command.view("clocks", title: "Clocks") { Clocks() }
///         }
///     }
@MainActor
public protocol Plugin {
    init()
    var manifest: Manifest { get }
    @CommandBuilder var commands: [Command] { get }
}

extension Plugin {
    public static func main() { _register(Self()) }
}

/// Everything Tinycast lists before a command runs. Tinycast reads it by calling the module,
/// with no permissions and no host APIs, and keeps it until the module changes.
public struct Manifest {
    public let name: String
    public let title: String
    public let description: String?
    /// An SF Symbol name.
    public let icon: String?
    public let author: String?
    public let permissions: [Permission]
    /// App link schemes the plugin may open, such as `cleanshot`; web and mail links need none.
    public let urlSchemes: [String]
    /// Settings every command reads, which the user fills in Settings › Plugins.
    public let preferences: [Preference]

    /// `name` is lowercase letters, digits and hyphens, and names the plugin's folder.
    public init(
        name: String, title: String, description: String? = nil, icon: String? = nil, author: String? = nil,
        permissions: [Permission] = [], urlSchemes: [String] = [], preferences: [Preference] = []
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.icon = icon
        self.author = author
        self.permissions = permissions
        self.urlSchemes = urlSchemes
        self.preferences = preferences
    }

    /// What a plugin may reach beyond its own screens. A plugin has no files, sockets or processes
    /// of its own: everything goes through Tinycast, which checks these.
    public enum Permission: String {
        /// `fetch(_:)`.
        case network
        /// `Clipboard.readText()`; copying and pasting never need it.
        case clipboard
        /// `getSelectedText()` and `getSelectedFinderItems()`.
        case selection
    }

    /// A setting the user fills in, as Raycast's `package.json` declares one.
    public struct Preference {
        let fields: [String: PluginValue]

        public static func textfield(
            _ name: String, title: String, description: String? = nil, placeholder: String? = nil,
            required: Bool = false, default value: String? = nil
        ) -> Preference {
            text("textfield", name, title, description, placeholder, required, value)
        }

        public static func password(
            _ name: String, title: String, description: String? = nil, placeholder: String? = nil,
            required: Bool = false
        ) -> Preference {
            text("password", name, title, description, placeholder, required, nil)
        }

        public static func checkbox(
            _ name: String, title: String, label: String? = nil, description: String? = nil,
            default value: Bool = false
        ) -> Preference {
            var fields = base("checkbox", name, title, description, false)
            fields["label"] = label.map(PluginValue.string)
            fields["defaultFlag"] = .bool(value)
            return Preference(fields: fields)
        }

        public static func dropdown(
            _ name: String, title: String, description: String? = nil, options: [(title: String, value: String)],
            default value: String? = nil
        ) -> Preference {
            var fields = base("dropdown", name, title, description, false)
            fields["data"] = .array(options.map { .object(["title": .string($0.title), "value": .string($0.value)]) })
            fields["defaultText"] = value.map(PluginValue.string)
            return Preference(fields: fields)
        }

        /// An application, a file or a folder, which reads as its path.
        public static func application(
            _ name: String, title: String, description: String? = nil, required: Bool = false
        ) -> Preference {
            Preference(fields: base("appPicker", name, title, description, required))
        }

        public static func file(
            _ name: String, title: String, description: String? = nil, required: Bool = false
        ) -> Preference {
            Preference(fields: base("file", name, title, description, required))
        }

        public static func directory(
            _ name: String, title: String, description: String? = nil, required: Bool = false
        ) -> Preference {
            Preference(fields: base("directory", name, title, description, required))
        }

        private static func base(
            _ type: String, _ name: String, _ title: String, _ description: String?, _ required: Bool
        ) -> [String: PluginValue] {
            var fields: [String: PluginValue] = [
                "name": .string(name), "type": .string(type), "title": .string(title)
            ]
            fields["description"] = description.map(PluginValue.string)
            if required { fields["required"] = .bool(true) }
            return fields
        }

        private static func text(
            _ type: String, _ name: String, _ title: String, _ description: String?, _ placeholder: String?,
            _ required: Bool, _ value: String?
        ) -> Preference {
            var fields = base(type, name, title, description, required)
            fields["placeholder"] = placeholder.map(PluginValue.string)
            fields["defaultText"] = value.map(PluginValue.string)
            return Preference(fields: fields)
        }
    }
}

/// One command: what the launcher lists, and its code.
public struct Command {
    public let name: String
    let fields: [String: PluginValue]
    let body: Body

    enum Body {
        /// Made once per launch, so the view's `@State` lasts across renders.
        case view(@MainActor () -> () -> [_Element])
        case action(@MainActor () async throws -> Void)
    }

    /// A field the launcher shows beside the command's name; the command reads it in
    /// `Launch.arguments`.
    public struct Argument {
        let fields: [String: PluginValue]

        public static func text(_ name: String, placeholder: String, required: Bool = false) -> Argument {
            Argument(fields: [
                "name": .string(name), "type": .string("text"), "placeholder": .string(placeholder),
                "required": .bool(required)
            ])
        }

        public static func password(_ name: String, placeholder: String, required: Bool = false) -> Argument {
            Argument(fields: [
                "name": .string(name), "type": .string("password"), "placeholder": .string(placeholder),
                "required": .bool(required)
            ])
        }
    }

    /// A command that opens a screen in the palette.
    public static func view<Content: View>(
        _ name: String, title: String, subtitle: String? = nil, description: String? = nil, icon: String? = nil,
        keywords: [String] = [], arguments: [Argument] = [], preferences: [Manifest.Preference] = [],
        @ViewBuilder content: @escaping @MainActor () -> Content
    ) -> Command {
        Command(
            name: name,
            fields: fields(
                "view", name, title, subtitle, description, icon, keywords, arguments, preferences, nil, false),
            body: .view({
                let view = content()
                return { _resolve(view) }
            }))
    }

    /// A command that does its work and closes the palette. With an `interval` such as `"10m"`, it
    /// also runs in the background once the user has run it.
    public static func action(
        _ name: String, title: String, subtitle: String? = nil, description: String? = nil, icon: String? = nil,
        keywords: [String] = [], arguments: [Argument] = [], preferences: [Manifest.Preference] = [],
        interval: String? = nil, disabledByDefault: Bool = false,
        run: @escaping @MainActor () async throws -> Void
    ) -> Command {
        Command(
            name: name,
            fields: fields(
                "no-view", name, title, subtitle, description, icon, keywords, arguments, preferences, interval,
                disabledByDefault),
            body: .action(run))
    }

    /// A menu in the menu bar: its body is a `MenuBarExtra`. With an `interval`, it refreshes on it.
    public static func menuBar<Content: View>(
        _ name: String, title: String, subtitle: String? = nil, description: String? = nil, icon: String? = nil,
        keywords: [String] = [], preferences: [Manifest.Preference] = [], interval: String? = nil,
        @ViewBuilder content: @escaping @MainActor () -> Content
    ) -> Command {
        Command(
            name: name,
            fields: fields(
                "menu-bar", name, title, subtitle, description, icon, keywords, [], preferences, interval, false),
            body: .view({
                let view = content()
                return { _resolve(view) }
            }))
    }

    private static func fields(
        _ mode: String, _ name: String, _ title: String, _ subtitle: String?, _ description: String?,
        _ icon: String?, _ keywords: [String], _ arguments: [Argument], _ preferences: [Manifest.Preference],
        _ interval: String?, _ disabledByDefault: Bool
    ) -> [String: PluginValue] {
        var fields: [String: PluginValue] = ["name": .string(name), "title": .string(title), "mode": .string(mode)]
        fields["subtitle"] = subtitle.map(PluginValue.string)
        fields["description"] = description.map(PluginValue.string)
        fields["icon"] = icon.map(PluginValue.string)
        if !keywords.isEmpty { fields["keywords"] = .array(keywords.map(PluginValue.string)) }
        if !arguments.isEmpty { fields["arguments"] = .array(arguments.map { .object($0.fields) }) }
        if !preferences.isEmpty { fields["preferences"] = .array(preferences.map { .object($0.fields) }) }
        fields["interval"] = interval.map(PluginValue.string)
        if disabledByDefault { fields["disabledByDefault"] = .bool(true) }
        return fields
    }
}

@resultBuilder
public enum CommandBuilder {
    public static func buildExpression(_ command: Command) -> [Command] { [command] }
    public static func buildBlock(_ parts: [Command]...) -> [Command] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [Command]?) -> [Command] { part ?? [] }
    public static func buildEither(first part: [Command]) -> [Command] { part }
    public static func buildEither(second part: [Command]) -> [Command] { part }
    public static func buildArray(_ parts: [[Command]]) -> [Command] { parts.flatMap { $0 } }
}

@MainActor func _manifestJSON(_ plugin: some Plugin) -> String {
    let manifest = plugin.manifest
    var fields: [String: PluginValue] = ["name": .string(manifest.name), "title": .string(manifest.title)]
    fields["description"] = manifest.description.map(PluginValue.string)
    fields["icon"] = manifest.icon.map(PluginValue.string)
    fields["author"] = manifest.author.map(PluginValue.string)
    if !manifest.permissions.isEmpty {
        fields["permissions"] = .array(manifest.permissions.map { .string($0.rawValue) })
    }
    if !manifest.urlSchemes.isEmpty { fields["urlSchemes"] = .array(manifest.urlSchemes.map(PluginValue.string)) }
    if !manifest.preferences.isEmpty { fields["preferences"] = .array(manifest.preferences.map { .object($0.fields) }) }
    fields["commands"] = .array(plugin.commands.map { .object($0.fields) })
    return PluginValue.object(fields).json
}

// MARK: - The launch

/// How the running command was launched.
@MainActor
public enum Launch {
    public static var commandName: String { _launch?.commandName ?? "" }

    /// What the launcher's argument fields held; every declared argument is here, empty when unfilled.
    public static var arguments: [String: String] { _launch?.arguments ?? [:] }

    /// The text typed in the launcher when the command ran from a fallback search, if any.
    public static var fallbackText: String? { _launch?.fallbackText }

    /// What `launchCommand(_:context:)` passed, or a deep link's `context`.
    public static var context: [String: PluginValue] { _launch?.launchContext ?? [:] }

    /// Whether the user ran the command or its schedule did.
    public static var type: LaunchType { _launch?.launchType == "background" ? .background : .userInitiated }

    /// The palette's appearance when the command started.
    public static var isDarkAppearance: Bool { _launch?.isDarkAppearance ?? false }
}

public enum LaunchType {
    case userInitiated
    case background
}

// MARK: - What every command can ask of Tinycast

/// Shows a short message, closing the palette.
@MainActor public func showHUD(_ text: String) {
    _send("feedback", "showHUD", [.string(text)])
}

/// Closes the palette; the command keeps running until it returns.
@MainActor public func closeMainWindow(clearRootSearch: Bool = false) {
    _send("window", "close", [.object(["clearRootSearch": .bool(clearRootSearch)])])
}

/// Back to the command's first screen.
@MainActor public func popToRoot() { _send("window", "popToRoot", []) }

@MainActor public func clearSearchBar() { _send("window", "clearSearchBar", []) }

/// Settings › Plugins, at this plugin.
@MainActor public func openPreferences() { _send("window", "openPreferences", [.string("extension")]) }

/// Opens a web address, a file path, or an app link the manifest allows, optionally with
/// `application` (a name, bundle id or path).
@MainActor public func open(_ destination: String, application: String? = nil) {
    var arguments: [PluginValue] = [.string(destination)]
    if let application { arguments.append(.string(application)) }
    _send("system", "open", arguments)
}

@MainActor public func showInFinder(_ path: String) { _send("system", "showInFinder", [.string(path)]) }

/// Leaves the screen a `NavigationLink` pushed.
@MainActor public func dismiss() { _ = _pop() }

/// Asks the user, the way the rest of Tinycast asks; true when they confirm.
@MainActor public func confirmAlert(
    title: String, message: String? = nil, primaryTitle: String? = nil, destructive: Bool = false
) async -> Bool {
    var primary: [String: PluginValue] = [:]
    if let primaryTitle { primary["title"] = .string(primaryTitle) }
    if destructive { primary["style"] = .string("destructive") }
    var payload: [String: PluginValue] = ["title": .string(title), "primaryAction": .object(primary)]
    if let message { payload["message"] = .string(message) }
    return (try? await _call("feedback", "confirmAlert", [.object(payload)]))?.boolValue ?? false
}

/// Runs another of this plugin's commands, with arguments and a context it reads in `Launch`.
@MainActor public func launchCommand(
    _ name: String, type: LaunchType = .userInitiated, arguments: [String: String] = [:],
    context: [String: PluginValue] = [:]
) async throws {
    let options: [String: PluginValue] = [
        "name": .string(name), "type": .string(type == .background ? "background" : "userInitiated"),
        "arguments": .object(arguments.mapValues(PluginValue.string)), "context": .object(context)
    ]
    _ = try await _call("system", "launchCommand", [.object(options)])
}

/// Changes the running command's subtitle in the launcher; nil puts back the manifest's.
@MainActor public func updateCommandMetadata(subtitle: String?) {
    _send("system", "updateCommandMetadata", [.object(["subtitle": subtitle.map(PluginValue.string) ?? .null])])
}

/// An installed application.
public struct Application {
    public let name: String
    public let path: String
    public let bundleID: String?

    init?(_ value: PluginValue) {
        guard let name = value["name"]?.text, let path = value["path"]?.text else { return nil }
        self.name = name
        self.path = path
        bundleID = value["bundleId"]?.text
    }
}

/// The applications the launcher lists, or those that open `path`.
@MainActor public func getApplications(_ path: String? = nil) async throws -> [Application] {
    let answer = try await _call("system", "applications", path.map { [.string($0)] } ?? [])
    return (answer.arrayValue ?? []).compactMap(Application.init)
}

@MainActor public func getDefaultApplication(_ path: String) async throws -> Application? {
    Application(try await _call("system", "defaultApplication", [.string(path)]))
}

/// The app that was in front before the palette opened.
@MainActor public func getFrontmostApplication() async throws -> Application? {
    Application(try await _call("system", "frontmostApplication", []))
}

/// The text selected in the frontmost app. Needs the `selection` permission.
@MainActor public func getSelectedText() async throws -> String {
    try await _call("system", "selectedText", []).text ?? ""
}

/// The files selected in Finder, as paths. Needs the `selection` permission.
@MainActor public func getSelectedFinderItems() async throws -> [String] {
    let answer = try await _call("system", "selectedFinderItems", [])
    return (answer.arrayValue ?? []).compactMap { $0["path"]?.text ?? $0.text }
}
