import Foundation
import Scrift

// Drives plugin commands the way the palette does — launch, frames, events, back — with the kit and
// fixtures from this repo, against a host that records every call.

@MainActor
final class TestHost: PluginHostAPI {
    var log: [String] = []
    var toasts: [PluginToast] = []
    var selectedText = ""

    /// A provider's tokens as the host keeps them, by provider id.
    var tokens: [String: PluginOAuthTokens] = [:]
    /// What the provider's redirect adds besides the request's state; `code` unless a test says.
    var redirectQuery = "code=granted"

    func perform(_ call: PluginHostCall) async throws -> PluginHostAnswer {
        log.append(Self.describe(call))
        switch call {
        case .showToast(let toast):
            toasts.append(toast)
            return .int(7)
        case .updateToast(_, let toast):
            toasts.append(toast)
            return .none
        case .confirm: return .bool(true)
        case .selectedText: return .text(selectedText)
        case .authorize(let url, _):
            // The provider sends the user back to the request's redirect, with its state.
            let items = URLComponents(string: url)?.queryItems ?? []
            let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
            let state = items.first { $0.name == "state" }?.value ?? ""
            let separator = redirect.contains("?") ? "&" : "?"
            return .text(redirect + separator + redirectQuery + "&state=" + state)
        case .setTokens(let provider, let value):
            tokens[provider] = value
            return .none
        case .tokens(let provider):
            return .tokens(tokens[provider])
        default:
            return .none
        }
    }

    func sessionEnded() {}

    func saw(_ prefix: String) -> Bool { log.contains { $0.hasPrefix(prefix) } }

    /// A call as one line: its name, then its arguments.
    static func describe(_ call: PluginHostCall) -> String {
        func toast(_ toast: PluginToast) -> String {
            ([toast.title, toast.message, toast.actionTitle, toast.actionToken].compactMap { $0 } + ["\(toast.style)"])
                .joined(separator: " ")
        }
        switch call {
        case .copy(let text, let concealed): return "copy \(text)" + (concealed ? " concealed" : "")
        case .paste(let text): return "paste \(text)"
        case .clearClipboard: return "clearClipboard"
        case .open(let target, let application): return "open \(target)" + (application.map { " with \($0)" } ?? "")
        case .showInFinder(let path): return "showInFinder \(path)"
        case .openWith(let path): return "openWith \(path)"
        case .trash(let paths): return "trash \(paths.joined(separator: " "))"
        case .showHUD(let text): return "showHUD \(text)"
        case .showToast(let value): return "showToast \(toast(value))"
        case .updateToast(let id, let value): return "updateToast \(id) \(toast(value))"
        case .hideToast(let id): return "hideToast \(id)"
        case .confirm(let alert): return "confirm \(alert.title)"
        case .closeMainWindow: return "closeMainWindow"
        case .popToRoot: return "popToRoot"
        case .clearSearchBar: return "clearSearchBar"
        case .openPreferences: return "openPreferences"
        case .launchCommand(let name, let background, let arguments, let context):
            let shown = arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                + context.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            return (["launchCommand \(name)\(background ? " background" : "")"] + shown).joined(separator: " ")
        case .updateCommandMetadata(let subtitle): return "updateCommandMetadata \(subtitle ?? "nil")"
        case .applications(let path): return "applications \(path ?? "")"
        case .defaultApplication(let path): return "defaultApplication \(path)"
        case .frontmostApplication: return "frontmostApplication"
        case .authorize(let url, let scheme): return "authorize \(url) \(scheme)"
        case .setTokens(let provider, let tokens): return "setTokens \(provider) \(tokens?.accessToken ?? "nil")"
        case .tokens(let provider): return "tokens \(provider)"
        case .selectedText: return "selectedText"
        case .selectedFinderItems: return "selectedFinderItems"
        }
    }
}

/// What the runtime told the host, as the palette would have drawn it.
@MainActor
final class Recorder: PluginRuntimeDelegate {
    var frames: [PluginFrame] = []
    var failure: String?
    var finished = false

    func runtime(_ runtime: any PluginRuntime, session: String, didRender frame: PluginFrame) { frames.append(frame) }
    func runtime(_ runtime: any PluginRuntime, session: String, didFail message: String) { failure = message }
    func runtime(_ runtime: any PluginRuntime, session: String, didFinish: Void) { finished = true }
}

extension PluginScreen {
    var sections: [PluginSection] {
        switch self {
        case .list(let list): list.sections
        case .grid(let grid): grid.sections
        default: []
        }
    }
}

/// One launched command.
@MainActor
final class Run {
    let runtime: any PluginRuntime
    let recorder = Recorder()
    let host: TestHost
    let session = "s"
    /// The effects the palette performed for actions it ran, as host calls describe them.
    var effects: [String] = []

    init(runtime: any PluginRuntime, host: TestHost) {
        self.runtime = runtime
        self.host = host
        runtime.setDelegate(recorder)
    }

    var frame: PluginFrame? { recorder.frames.last }
    var screen: PluginScreen? { frame?.screen }
    var chrome: PluginChrome? { screen?.chrome }
    var depth: Int { frame?.depth ?? 0 }

    var list: PluginListScreen? {
        if case .list(let list) = screen { return list }
        return nil
    }
    var grid: PluginGridScreen? {
        if case .grid(let grid) = screen { return grid }
        return nil
    }
    var detail: PluginDetailScreen? {
        if case .detail(let detail) = screen { return detail }
        return nil
    }
    var form: PluginFormScreen? {
        if case .form(let form) = screen { return form }
        return nil
    }
    var menuBar: PluginMenuBarScreen? {
        if case .menuBar(let menu) = screen { return menu }
        return nil
    }

    func section(_ title: String?) -> PluginSection? { screen?.sections.first { $0.title == title } }
    var rows: [PluginRow] { screen?.sections.flatMap(\.rows) ?? [] }
    func row(_ title: String) -> PluginRow? { rows.first { $0.title.plain == title } }
    var titles: [String] { rows.map { $0.title.plain ?? "" } }

    func field(_ title: String) -> PluginField? { form?.fields.first { $0.title == title } }

    /// The action titled `title` among `actions`, however deep.
    static func action(_ title: String, in actions: [PluginAction]) -> PluginAction? {
        for action in actions {
            if action.title == title { return action }
            if let found = Self.action(title, in: action.children) { return found }
        }
        return nil
    }

    func action(_ title: String, of row: PluginRow?) -> PluginAction? { row.flatMap { Self.action(title, in: $0.actions) } }
    func toolbar(_ title: String) -> PluginAction? { chrome.flatMap { Self.action(title, in: $0.actions) } }

    func menuItem(_ title: String, in items: [PluginMenuItem]? = nil) -> PluginMenuItem? {
        for item in items ?? menuBar?.items ?? [] {
            if item.title == title { return item }
            if let found = menuItem(title, in: item.children) { return found }
        }
        return nil
    }

    /// Runs an action as the palette does: its effect, then its handler, from the frame it's in.
    func perform(_ action: PluginAction?, generation: Int? = nil) async {
        guard let action else {
            print("      (no such action)")
            return
        }
        if let effect = action.effect { effects.append("\(effect)") }
        if let handler = action.handler { await perform(handler, generation: generation) }
    }

    func perform(_ item: PluginMenuItem?) async {
        guard let handler = item?.handler else {
            print("      (no such menu item)")
            return
        }
        await perform(handler)
    }

    func perform(_ handler: Int, generation: Int? = nil) async {
        await send(.perform(handler, generation: generation ?? frame?.generation ?? 0))
    }

    func set(_ node: String, _ value: PluginFieldValue) async {
        await send(.set(node, value: value, generation: frame?.generation ?? 0))
    }

    func search(_ text: String) async { await send(.search(text, generation: frame?.generation ?? 0)) }
    func back() async { await send(.back) }

    func send(_ event: PluginEvent) async {
        await runtime.send(event, session: session, completesSession: false)
    }

    func stop() async { await runtime.stop(session: session) }
}

nonisolated(unsafe) var failures = 0

@MainActor func check(_ description: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(description)")
    } else {
        print("FAIL  \(description)")
        failures += 1
    }
}

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
let fixtures = root.appending(path: "Fixtures")
let examples = root.appending(path: "../../Examples/Plugins").standardized
let kitDirectory = root.appending(path: "../../Tinycast/Resources/PluginKit").standardized
let descriptionDirectory = root.appending(path: "../../Tinycast/Resources/PluginDescription").standardized
nonisolated(unsafe) var pluginDescription = PluginSources(files: [])
nonisolated(unsafe) var kit = PluginSources(files: [])

/// A setup step that can't fail without every later check failing too, so it ends the run.
@MainActor func must<T>(_ what: String, _ body: () throws -> T) -> T {
    do {
        return try body()
    } catch {
        print("FAIL  \(what): \(error)")
        exit(1)
    }
}

/// A `Manifest.swift`'s text, run as the catalog runs it.
@MainActor func evaluate(_ swift: String) -> Result<PluginManifest, PluginManifestError> {
    PluginManifestReader.evaluate(swift, description: pluginDescription)
}

@MainActor func manifest(_ swift: String) -> PluginManifest {
    must("run a manifest") { try evaluate(swift).get() }
}

/// The error a manifest fails with, or nil when it runs.
@MainActor func manifestError(_ swift: String) -> PluginManifestError? {
    if case .failure(let error) = evaluate(swift) { return error }
    return nil
}

@MainActor func manifestText(_ folder: URL) -> String {
    must("read \(folder.lastPathComponent)/Manifest.swift") {
        try String(contentsOf: folder.appending(path: "Manifest.swift"), encoding: .utf8)
    }
}

func folder(_ name: String) -> URL {
    FileManager.default.fileExists(atPath: fixtures.appending(path: name).path)
        ? fixtures.appending(path: name) : examples.appending(path: name)
}

@MainActor func manifest(at name: String) -> PluginManifest {
    manifest(manifestText(folder(name)))
}

/// A one-command manifest around `arguments`, which go before `commands:`.
func plugin(_ arguments: String = #"name: "a", title: "A","#, commands: String = #".view("x", title: "X")"#)
    -> String
{
    """
    import PluginDescription

    let plugin = Plugin(\(arguments) commands: [\(commands)])
    """
}

@MainActor func sources(_ name: String) -> PluginSources {
    must("read \(name)'s sources") { try PluginSources.read(from: folder(name)) }
}

/// Launches one of `manifest`'s commands from the plugin in `fixture` (its folder name).
@MainActor func launch(
    _ manifest: PluginManifest, _ command: String, fixture: String, storage: any PluginStorage = PluginMemoryStorage(),
    host: TestHost = TestHost(), arguments: [String: String] = [:], preferences: [String: PluginValue] = [:],
    background: Bool = false, launchContext: [String: PluginValue] = [:], helper: PluginHelperClient? = nil
) async throws -> Run {
    let runtime: any PluginRuntime =
        if let helper {
            RemotePluginRuntime(
                client: helper, plugin: manifest, directory: folder(fixture), storage: storage, hostAPI: host,
                appScheme: "tinycast", kitDirectory: kitDirectory)
        } else {
            ScriftPluginRuntime(
                plugin: manifest, directory: folder(fixture), storage: storage, hostAPI: host, appScheme: "tinycast",
                kitSources: { kit })
        }
    let run = Run(runtime: runtime, host: host)
    let launch = PluginLaunch(
        commandName: command, isBackground: background, arguments: arguments, preferences: preferences,
        fallbackText: nil, launchContext: launchContext, isDarkAppearance: false)
    try await runtime.launch(session: run.session, launch: launch)
    return run
}

@MainActor func started(
    _ manifest: PluginManifest, _ command: String, fixture: String, storage: any PluginStorage = PluginMemoryStorage(),
    host: TestHost = TestHost(), arguments: [String: String] = [:], preferences: [String: PluginValue] = [:],
    background: Bool = false, launchContext: [String: PluginValue] = [:], helper: PluginHelperClient? = nil
) async -> Run {
    do {
        return try await launch(
            manifest, command, fixture: fixture, storage: storage, host: host, arguments: arguments,
            preferences: preferences, background: background, launchContext: launchContext, helper: helper)
    } catch {
        print("FAIL  launch \(command): \(error.localizedDescription)")
        exit(1)
    }
}

/// Why launching fails, or nil when it doesn't.
@MainActor func launchError(
    _ manifest: PluginManifest, _ command: String, fixture: String, helper: PluginHelperClient? = nil
) async -> String? {
    do {
        let run = try await launch(manifest, command, fixture: fixture, helper: helper)
        await run.stop()
        return nil
    } catch {
        return error.localizedDescription
    }
}

@MainActor func until(seconds: Int = 2, _ condition: () -> Bool) async {
    for _ in 0..<(seconds * 100) where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
}

/// A frame as JSON with sorted keys, the form the snapshots in Fixtures/frames keep; its generation
/// counts renders, which a task's timing changes, so it's left out.
func snapshot(_ frame: PluginFrame?) -> String {
    var frame = frame
    frame?.generation = 0
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return frame.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) + "\n" } ?? ""
}

/// Whether `frame` matches the snapshot `name`; `UPDATE_SNAPSHOTS=1` writes it instead.
func matchesSnapshot(_ frame: PluginFrame?, _ name: String) -> Bool {
    let file = fixtures.appending(path: "frames/\(name).json")
    let text = snapshot(frame)
    if ProcessInfo.processInfo.environment["UPDATE_SNAPSHOTS"] != nil {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
        return true
    }
    let kept = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    if kept != text { print("      \(name) differs from Fixtures/frames/\(name).json:\n\(text)") }
    return kept == text
}

@MainActor func run() async {
    kit = must("read the kit") { try PluginSources.read(from: kitDirectory, requiringMain: false) }
    pluginDescription = must("read the plugin description") {
        try PluginSources.read(from: descriptionDirectory, requiringMain: false)
    }

    // MARK: Manifest.swift

    let manifestStarted = ContinuousClock.now
    _ = manifest(manifestText(examples.appending(path: "cleanshot-x")))
    print("      CleanShot X manifest run \(ContinuousClock.now - manifestStarted)")
    let warmManifest = ContinuousClock.now
    _ = manifest(manifestText(examples.appending(path: "cleanshot-x")))
    print("      and again \(ContinuousClock.now - warmManifest)")
    let full = manifest(
        plugin(
            #"name: "a", title: "A", description: "D", icon: "star", author: "Me", "#
                + #"permissions: [.network, .clipboard, .openURLs(schemes: ["cleanshot", "things"])],"#,
            commands: #".view("x", title: "X", subtitle: "S", icon: "i", keywords: ["k"]), .action("y", title: "Y")"#))
    check("a manifest runs", full.name == "a" && full.title == "A" && full.description == "D")
    check("and keeps its icon and author", full.icon == "star" && full.author == "Me")
    check("its permissions cross", full.permissions == [.network, .clipboard])
    check("openURLs grants its schemes", full.urlSchemes == ["cleanshot", "things"])
    check("commands keep their order and fields", full.commands.map(\.name) == ["x", "y"] && full.commands[0].keywords == ["k"])
    check("view and action set the mode", full.commands.map(\.mode) == [.view, .action])
    check("the JSON form reads back as the same manifest", (try? PluginManifest.decode(full.json())) == full)
    check(
        "an empty list or a missing value is left out of it",
        !String(decoding: manifest(plugin()).json(), as: UTF8.self).contains("keywords"))
    check("a manifest without commands is refused", manifestError(plugin(commands: "")) == .noCommands)
    if case .compile(let diagnostics) = manifestError(plugin(#"name: "a", title: "A", permissions: [.camera],"#)) {
        check("an unknown permission doesn't compile", diagnostics.contains("camera"))
        check("and says where", diagnostics.contains("Manifest.swift:3"))
    } else {
        check("an unknown permission doesn't compile", false)
    }
    check("a name with capitals is refused", manifestError(plugin(#"name: "World", title: "A","#)) == .invalidName("World"))
    check(
        "a command declared twice is refused",
        manifestError(plugin(commands: #".view("x", title: "X"), .action("x", title: "Y")"#)) == .duplicateCommand("x"))
    check(
        "a forbidden scheme is refused",
        manifestError(plugin(#"name: "a", title: "A", permissions: [.openURLs(schemes: ["raycast"])],"#))
            == .invalidURLScheme("raycast"))
    check("a manifest that creates no Plugin says so", manifestError("import PluginDescription\n") == .noPlugin)
    check(
        "nor may it create two",
        manifestError(plugin() + "\nlet other = Plugin(name: \"b\", title: \"B\", commands: [.view(\"x\", title: \"X\")])")
            == .severalPlugins(2))
    if case .panic = manifestError(plugin() + "\nwhile true {}") {
        check("a manifest that never ends is stopped", true)
    } else {
        check("a manifest that never ends is stopped", false)
    }
    if case .compile = manifestError("import Foundation\nlet session = URLSession.shared\n" + plugin()) {
        check("a manifest has no network, whatever it declares", true)
    } else {
        check("a manifest has no network, whatever it declares", false)
    }
    check("the manifest isn't one of the plugin's sources", !sources("cities").files.contains { $0.name == "Manifest.swift" })

    check(
        "an interval is a duration, kept in seconds",
        manifest(plugin(commands: #".menuBar("x", title: "X", interval: .minutes(10))"#)).commands.first?.interval == 600)
    check(
        "an interval of nothing is refused",
        manifestError(plugin(commands: #".action("x", title: "X", interval: .seconds(0))"#)) == .invalidInterval(0))

    // MARK: The catalog and its cache

    let pluginsFolder = FileManager.default.temporaryDirectory.appending(path: "plugins-\(UUID())")
    let cacheFolder = FileManager.default.temporaryDirectory.appending(path: "manifests-\(UUID())")
    for name in ["cities", "gated"] {
        must("copy \(name)") {
            try FileManager.default.createDirectory(at: pluginsFolder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixtures.appending(path: name), to: pluginsFolder.appending(path: name))
        }
    }
    let stale = cacheFolder.appending(path: "stale.json")
    must("seed the cache") {
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: stale)
    }
    let scanned = PluginCatalog.scan(pluginsFolder, description: pluginDescription, cache: cacheFolder)
    check("the catalog lists each plugin by its manifest", scanned.map(\.id) == ["fixture", "gated"])
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: cacheFolder.path)) ?? []
    check("and keeps what each declared", entries.count == 2 && entries.allSatisfy { $0.hasSuffix(".json") })
    check("an entry no plugin uses is removed", !entries.contains("stale.json"))
    let rescanned = PluginCatalog.scan(pluginsFolder, description: pluginDescription, cache: cacheFolder)
    check("a rescan reads the cache to the same plugins", rescanned == scanned)
    let gatedManifest = pluginsFolder.appending(path: "gated/Manifest.swift")
    must("edit gated's manifest") {
        try manifestText(pluginsFolder.appending(path: "gated"))
            .replacingOccurrences(of: #"title: "Gated""#, with: #"title: "Gated Again""#)
            .write(to: gatedManifest, atomically: true, encoding: .utf8)
    }
    let edited = PluginCatalog.scan(pluginsFolder, description: pluginDescription, cache: cacheFolder)
    check("an edited manifest runs again", edited.last?.title == "Gated Again")
    check("and its old entry goes", ((try? FileManager.default.contentsOfDirectory(atPath: cacheFolder.path)) ?? []).count == 2)
    let unlisted = PluginCatalog.scan(pluginsFolder, description: nil, cache: cacheFolder)
    check(
        "without the description no plugin lists",
        unlisted.allSatisfy { if case .failure(.descriptionMissing) = $0.manifest { true } else { false } })
    check("and the cache is left alone", ((try? FileManager.default.contentsOfDirectory(atPath: cacheFolder.path)) ?? []).count == 2)
    try? FileManager.default.removeItem(at: pluginsFolder)
    try? FileManager.default.removeItem(at: cacheFolder)
    check("module names are Swift identifiers", InstalledPlugin.moduleName(for: "world-clock") == "WorldClock")
    check("a module name never shadows the kit", InstalledPlugin.moduleName(for: "tinycast") != "Tinycast")

    // MARK: A plugin's commands

    let kitchen = manifest(at: "kitchen")
    check(
        "every command keeps its mode",
        kitchen.commands.map(\.mode) == [.view, .view, .menuBar, .action, .action, .action])
    check("a menu bar interval is kept", kitchen.commands[2].interval == 60)
    check("arguments are kept", kitchen.commands[0].arguments.map(\.name) == ["subject"])
    check("and the plugin's preferences", kitchen.preferences.map(\.name) == ["greeting", "loud"])
    check("the JSON form keeps them", (try? PluginManifest.decode(kitchen.json())) == kitchen)

    // MARK: A view command, end to end

    let cities = manifest(at: "cities")
    let clock = ContinuousClock()
    let storage = PluginMemoryStorage()
    let started0 = clock.now
    let session = await started(cities, "cities", fixture: "cities", storage: storage)
    print("      first launch \(clock.now - started0)")
    check("a frame arrives on launch", session.list != nil)
    check("of this version of the contract", session.frame?.version == PluginProtocolVersion.current)
    check("loading at first", session.chrome?.isLoading == true)
    check("with its title", session.chrome?.title == "Cities")
    check("and its search field, bound to the plugin", session.chrome?.search?.prompt == "Filter cities"
        && session.chrome?.search?.binding == "search")
    await until { session.chrome?.isLoading == false }
    check("its task loads the rows", session.section("Cities")?.rows.count == 3)
    check("the loaded list matches its snapshot", matchesSnapshot(session.frame, "cities"))
    check("row ids come from ForEach's data", session.rows.map(\.id) == ["Tokyo", "London", "Lima"])
    check(
        "a Link is an effect too",
        session.action("Map", of: session.row("Tokyo"))?.effect == .openURL("https://maps.apple.com/?q=Tokyo", application: nil))
    check("an if in a context menu leaves an item out", session.action("Map", of: session.row("Lima")) == nil)

    await session.search("l")
    check("typing filters through the binding", session.titles == ["London", "Lima"])
    check("the field reads back what was typed", session.chrome?.search?.text == "l")
    check("a row keeps its id when the rows around it change", session.rows.map(\.id) == ["London", "Lima"])

    let lima = session.row("Lima")
    check("a row has its badge", lima.map { if case .count(4) = $0.accessories.first { true } else { false } } == true)
    check("and its symbol", lima.map { if case .symbol("building.2", _) = $0.icon { true } else { false } } == true)
    check("and its subtitle", lima?.subtitle?.plain == "Peru")
    let copy = session.action("Copy to Clipboard", of: lima)
    check("the first context menu item is the primary action", lima?.actions.first?.title == "Copy to Clipboard")
    check("a CopyButton is an effect the host performs", copy?.effect == .copy("Lima", concealed: false) && copy?.handler == nil)
    let pin = session.action("Pin", of: lima)
    check(
        "a declared shortcut crosses",
        pin?.shortcut == PluginShortcut(key: .character("p"), modifiers: [.command, .shift]))
    await session.perform(pin)
    check("@AppStorage writes the plugin's storage, as JSON", storage.value(plugin: "fixture", key: "pinned") == "\"Lima\"")
    check("and the list shows the pin", session.screen?.sections.first?.title == "Pinned")
    let pinnedRow = session.section("Pinned")?.rows.first
    check(
        "tinted",
        pinnedRow.map { if case .symbol("pin", .semantic(.orange)?) = $0.icon { true } else { false } } == true)

    // MARK: Generations

    let before = session.frame
    let beforeLondon = before.flatMap { _ in session.action("Pin", of: session.row("London")) }
    await session.search("")
    check("each frame is a new generation", (session.frame?.generation ?? 0) > (before?.generation ?? 0))
    if let handler = beforeLondon?.handler, let generation = before?.generation {
        await session.perform(handler, generation: generation)
    }
    check(
        "a handler from a recent frame still runs, as the host drew it",
        storage.value(plugin: "fixture", key: "pinned") == "\"London\"")
    let old = session.frame
    let oldTokyo = session.action("Pin", of: session.row("Tokyo"))
    for text in ["o", "", "o", "", "o", "", "o", "", "o", ""] { await session.search(text) }
    if let handler = oldTokyo?.handler, let generation = old?.generation {
        await session.perform(handler, generation: generation)
    }
    check("one from an expired frame is dropped", storage.value(plugin: "fixture", key: "pinned") == "\"London\"")
    check(
        "a handler number means another action in each generation's table, not a stale one",
        session.action("Pin", of: session.row("Tokyo"))?.handler != nil)

    // MARK: Navigation

    await session.perform(session.action("Show", of: session.row("Lima")))
    check("a NavigationLink pushes its view", session.detail?.markdown.contains("Lima") == true)
    check("onto the frame's depth", session.depth == 2)
    await session.perform(session.toolbar("Visit"))
    await session.perform(session.toolbar("Visit"))
    check("a pushed view keeps its @State", session.detail?.markdown.contains("Visited 2 times") == true)
    let country = session.detail?.metadata.first
    check(
        "LabeledContent becomes metadata",
        country.map { if case .label("Country", let text, _) = $0 { text.plain == "Peru" } else { false } } == true)
    check("the detail matches its snapshot", matchesSnapshot(session.frame, "city-detail"))
    await session.perform(session.toolbar("Back"))
    check("@Environment(\\.dismiss) goes back", session.list != nil && session.depth == 1)
    await session.perform(session.action("Show", of: session.row("Lima")))
    await session.back()
    check("so does the host's back", session.list != nil && session.depth == 1)
    let frames = session.recorder.frames.count
    await session.back()
    check("the root can't go back", session.depth == 1 && session.recorder.frames.count == frames)
    await session.stop()

    // MARK: Storage outlives the session

    let reopened = await started(cities, "cities", fixture: "cities", storage: storage)
    check("a new session reads the stored pin", reopened.section("Pinned")?.rows.first?.title.plain == "London")
    await reopened.stop()

    // MARK: An action command

    let warm = clock.now
    let hello = await started(cities, "hello", fixture: "cities")
    print("      warm launch \(clock.now - warm)")
    await until { hello.recorder.finished || hello.recorder.failure != nil }
    check("an action command finishes", hello.recorder.finished)
    try? await Task.sleep(for: .milliseconds(20))
    check("and its HUD reaches the host", hello.host.saw("showHUD Hello from hello"))
    check("without drawing a frame", hello.recorder.frames.isEmpty)

    // MARK: Forms

    let note = await started(kitchen, "note", fixture: "kitchen", arguments: ["subject": "Groceries"])
    check("a form renders", note.form != nil)
    check("the form matches its snapshot", matchesSnapshot(note.frame, "note"))
    let subject = note.field("Subject")
    check(
        "an argument reaches the command",
        subject.map { if case .textField("Groceries", "What about?", false) = $0.kind { true } else { false } } == true)
    check("a field's id defaults to its title", subject?.id == "Subject")
    await note.set("Subject", .text("Milk"))
    check(
        "a change writes the binding",
        note.field("Subject").map { if case .textField("Milk", _, _) = $0.kind { true } else { false } } == true)
    await note.set("Kind", .index(1))
    await note.set("Tags", .indices([0, 1]))
    await note.set("Urgent", .bool(true))
    check(
        "a toggle toggles",
        note.field("Urgent").map { if case .toggle(_, isOn: true) = $0.kind { true } else { false } } == true)
    check(
        "a picker's options are its tagged views",
        note.field("Kind").map {
            if case .picker(let picker) = $0.kind { picker.options.map(\.title) == ["Idea", "Task"] && picker.selection == 1 } else { false }
        } == true)
    await note.set("Due", .date(1_798_106_400))
    check(
        "a date crosses",
        note.field("Due").map { if case .datePicker(1_798_106_400, _) = $0.kind { true } else { false } } == true)
    check("a divider becomes the form's separator", note.form?.fields.contains { $0.kind == .separator } == true)
    await note.perform(note.toolbar("Save"))
    check(
        "a toolbar button runs with the form's values",
        note.field("Status").map { $0.kind == .text("Saved Milk task home,work") } == true)
    await note.stop()
    let kitchenStorage = PluginMemoryStorage()
    let first = await started(kitchen, "note", fixture: "kitchen", storage: kitchenStorage)
    await first.set("Subject", .text("Remembered"))
    await first.stop()
    let second = await started(kitchen, "note", fixture: "kitchen", storage: kitchenStorage)
    check(
        "an @AppStorage field starts from what was typed last",
        second.field("Subject").map { if case .textField("Remembered", _, _) = $0.kind { true } else { false } } == true)
    await second.stop()

    // MARK: Grids and the toolbar's picker

    let colors = await started(kitchen, "colors", fixture: "kitchen", storage: kitchenStorage)
    check("a grid renders", colors.grid?.columns == 4 && colors.grid?.aspectRatio == 1.5)
    let tiles = colors.section("Swatches")?.rows ?? []
    check("its items are tiles", tiles.count == 3)
    check("a colour tile is a swatch", tiles.first.map { $0.content == .color(.semantic(.red)) || $0.icon == .color(.semantic(.red)) } == true)
    check("the grid matches its snapshot", matchesSnapshot(colors.frame, "colors"))
    let palette = colors.chrome?.pickers.first
    check("a toolbar Picker sits beside the search", palette?.title == "Palette" && palette?.options.count == 2 && palette?.selection == 0)
    if let palette { await colors.set(palette.id, .index(1)) }
    check(
        "choosing writes @AppStorage",
        kitchenStorage.value(plugin: "kitchen", key: "palette") == "\"cool\"" && colors.section("Swatches")?.rows.last?.title.plain == "Ice")
    await colors.stop()

    // MARK: The palette's layout

    // A scope of its own: these helpers would shadow names the later checks use.
    do {
        func text(_ words: String) -> PluginText { PluginText(content: .plain(words), color: nil, isBold: false, isMonospaced: false) }
        func button(_ title: String, handler: Int? = nil, children: [PluginAction] = [], effect: PluginEffect? = nil) -> PluginAction {
            PluginAction(
                id: title, title: title, icon: nil, shortcut: nil, role: nil, effect: effect, handler: handler, children: children)
        }
        func row(_ id: String, subtitle: String? = nil, keywords: [String] = [], actions: [PluginAction] = []) -> PluginRow {
            PluginRow(
                id: id, title: text(id), subtitle: subtitle.map(text), icon: nil, content: nil, accessories: [],
                keywords: keywords, actions: actions, detail: nil, isRedacted: false)
        }
        func chrome(binding: String? = nil, actions: [PluginAction] = []) -> PluginChrome {
            PluginChrome(
                title: nil, search: PluginSearchField(text: "", prompt: nil, binding: binding), pickers: [], actions: actions,
                isLoading: false)
        }
        func list(_ sections: [PluginSection], binding: String? = nil, actions: [PluginAction] = [], selection: String? = nil,
                  empty: PluginEmptyState? = nil) -> PluginScreen {
            .list(PluginListScreen(
                chrome: chrome(binding: binding, actions: actions), sections: sections, emptyState: empty, showsDetail: false,
                selection: selection, selectionBinding: nil))
        }
        let fruit = PluginSection(id: "fruit", title: "Fruit", subtitle: nil, rows: [
            row("Apple", actions: [button("Eat", handler: 1), button("Share", children: [button("Mail", handler: 2)], effect: .menu)]),
            row("Banana", subtitle: "yellow"),
        ])
        let tools = PluginSection(id: "tools", title: "Tools", subtitle: nil, rows: [row("Hammer", keywords: ["nail"])])
        let unfiltered = PluginScreenLayout(screen: list([fruit, tools]), query: "")
        check("the layout walks every row in order", unfiltered.items.map(\.id) == ["fruit/Apple", "fruit/Banana", "tools/Hammer"])
        check("an empty query keeps the sections", unfiltered.sections.map(\.id) == ["fruit", "tools"])
        check("a list with no search binding filters by title", PluginScreenLayout(screen: list([fruit, tools]), query: "ban").items.map(\.id) == ["fruit/Banana"])
        check("and by subtitle", PluginScreenLayout(screen: list([fruit, tools]), query: "yellow").items.count == 1)
        let nail = PluginScreenLayout(screen: list([fruit, tools]), query: "nail")
        check("and by keyword, dropping a section left empty", nail.items.map(\.id) == ["tools/Hammer"] && nail.sections.map(\.id) == ["tools"])
        check("a list with a search binding is the plugin's to filter", PluginScreenLayout(screen: list([fruit, tools], binding: "search"), query: "ban").items.count == 3)
        check("indexes follow the filtered order", nail.items.first?.index == 0)
        check("↵ runs a row's first action", unfiltered.primaryAction(at: 0)?.title == "Eat")
        let screenWide = PluginScreenLayout(screen: list([fruit, tools], actions: [button("Refresh", handler: 9)]), query: "")
        check("a row without actions falls back to the toolbar's", screenWide.primaryAction(at: 1)?.title == "Refresh")
        check("⌘K lists the row's actions, then the toolbar's", screenWide.actions(at: 0).row.count == 2 && screenWide.actions(at: 0).screen.count == 1)
        check("a menu flattens to what it holds", unfiltered.actions(at: 0).row.flatMap(\.flattened).map(\.title) == ["Eat", "Mail"])
        let empty = PluginScreenLayout(
            screen: list([], empty: PluginEmptyState(title: "None", description: nil, icon: nil, actions: [button("Create", handler: 3)])), query: "")
        check("an empty list acts through its empty state", empty.primaryAction(at: 0)?.title == "Create")
        check("a requested selection lands on its row", PluginScreenLayout(screen: list([fruit, tools], selection: "Hammer"), query: "").requestedSelection == 2)

        let five = PluginSection(id: "a", title: nil, subtitle: nil, rows: (0..<5).map { row("a\($0)") })
        let three = PluginSection(id: "b", title: nil, subtitle: nil, rows: (0..<3).map { row("b\($0)") })
        let grid = PluginScreenLayout(
            screen: .grid(PluginGridScreen(
                chrome: chrome(), sections: [five, three], emptyState: nil, columns: 4, aspectRatio: 1, fit: .contain,
                inset: .none, selection: nil, selectionBinding: nil)),
            query: "")
        check("↓ in a grid moves a row down", grid.gridMove(1, from: 0, columns: 4) == 4)
        check("or to the section's last tile when the row below is short", grid.gridMove(1, from: 1, columns: 4) == 4)
        check("and from the last row into the next section's column", grid.gridMove(1, from: 4, columns: 4) == 5)
        check("↑ from a section's first row goes to the last row above", grid.gridMove(-1, from: 6, columns: 4) == 4)
        check("and stops at the top", grid.gridMove(-1, from: 2, columns: 4) == 2)
        check("↓ stops at the bottom", grid.gridMove(1, from: 7, columns: 4) == 7)

        let fields = PluginFormScreen(chrome: chrome(), fields: [
            PluginField(id: "note", title: nil, info: nil, error: nil, autoFocus: false, kind: .text("Read me")),
            PluginField(id: "name", title: "Name", info: nil, error: nil, autoFocus: false, kind: .textField("", prompt: nil, isSecure: false)),
            PluginField(id: "rule", title: nil, info: nil, error: nil, autoFocus: false, kind: .separator),
            PluginField(id: "body", title: "Body", info: nil, error: nil, autoFocus: true, kind: .textEditor("", prompt: nil)),
        ])
        let formLayout = PluginScreenLayout(screen: .form(fields), query: "ignored")
        check("a form's rows are the fields that take focus", formLayout.items.map(\.id) == ["name", "body"])
        check("and it starts in the one that asks", formLayout.autoFocusIndex == 1)

        // MARK: Command references and links

        let ref = PluginCommandRef(plugin: "hacker-news", command: "stories")
        check("a command's entry ID names its plugin and command", ref.entryID == "plugin:hacker-news/stories")
        check("and reads back", PluginCommandRef(entryID: ref.entryID) == ref)
        check("another kind of entry isn't a plugin command", PluginCommandRef(entryID: "extension:demo/search") == nil)
        check("nor is one missing a half", PluginCommandRef(entryID: "plugin:demo") == nil && PluginCommandRef(entryID: "plugin:/x") == nil)
        let link = PluginDeepLink.url(ref, arguments: ["query": "swift & rust"], scheme: "tinycast")
        check("a deep link reads back with its arguments", link.flatMap(PluginDeepLink.parse).map { $0.command == ref && $0.arguments == ["query": "swift & rust"] } == true)
        let background = URL(string: "tinycast-dev://plugins/hacker-news/stories?launchType=background&fallbackText=hi")!
        check("the dev scheme is claimed too", PluginDeepLink.claims(background))
        check("a link can ask to run in the background", PluginDeepLink.parse(background).map { $0.isBackground && $0.fallbackText == "hi" } == true)
        check("another host isn't a plugin link", !PluginDeepLink.claims(URL(string: "tinycast://extensions/a/b")!))

        let two = manifest(plugin(#"name: "a", title: "A","#, commands: #".view("x", title: "X"), .view("y", title: "Y")"#))
        let one = manifest(plugin(#"name: "a", title: "A","#, commands: #".view("x", title: "X")"#))
        let installed = InstalledPlugin(directory: URL(filePath: "/p/a"), manifest: .success(two))
        check(
            "a removed folder takes its commands' references",
            InstalledPlugin.removedCommands(from: [installed], to: []) == ["plugin:a/x", "plugin:a/y"])
        check(
            "a command dropped from the manifest takes its own",
            InstalledPlugin.removedCommands(from: [installed], to: [InstalledPlugin(directory: URL(filePath: "/p/a"), manifest: .success(one))])
                == ["plugin:a/y"])
        check(
            "a manifest that stops compiling takes nothing",
            InstalledPlugin.removedCommands(
                from: [installed], to: [InstalledPlugin(directory: URL(filePath: "/p/a"), manifest: .failure(.noCommands))]).isEmpty)
    }

    // MARK: Menu bar commands

    let status = await started(kitchen, "status", fixture: "kitchen")
    check("a menu bar command renders its extra", status.menuBar?.title == "0")
    check("the menu matches its snapshot", matchesSnapshot(status.frame, "status"))
    let add = status.menuItem("Add")
    check("its items have shortcuts, ⌘ by default", add?.shortcut?.modifiers == [.command])
    await status.perform(add)
    check("an item's action renders again", status.menuBar?.title == "1")
    check(
        "sections, submenus and dividers keep their kinds",
        status.menuItem("More")?.kind == .section && status.menuItem("Reset")?.kind == .submenu
            && status.menuBar?.items.contains { $0.kind == .separator } == true)
    await status.perform(status.menuItem("To zero"))
    check("a submenu's items run", status.menuBar?.title == "0")
    await status.stop()

    // MARK: Preferences, toasts and launching commands

    let toast = await started(
        kitchen, "toast", fixture: "kitchen", preferences: ["greeting": .string("Howdy"), "loud": .bool(true)],
        background: true)
    await until { toast.recorder.finished || toast.recorder.failure != nil }
    try? await Task.sleep(for: .milliseconds(30))
    check("an action command reads its preferences", toast.host.saw("showToast HOWDY"))
    check("a toast changes after it shows", toast.host.log.contains { $0.hasPrefix("updateToast 7") && $0.contains("background") })
    let token = toast.host.toasts.last?.actionToken
    check("its button is a token for the script's closure", token != nil && toast.host.toasts.last?.actionTitle == "Undo")
    if let token { await toast.runtime.runToastAction(token: token) }
    try? await Task.sleep(for: .milliseconds(30))
    check("which runs it", toast.host.saw("showHUD Undone"))

    let hop = await started(kitchen, "hop", fixture: "kitchen")
    await until { hop.recorder.finished || hop.recorder.failure != nil }
    try? await Task.sleep(for: .milliseconds(20))
    check("launchCommand asks the host", hop.host.log.contains { $0.hasPrefix("launchCommand note") && $0.contains("subject=From hop") })
    let hopped = await started(
        kitchen, "note", fixture: "kitchen", arguments: ["subject": "From hop"], launchContext: ["origin": .string("hop")])
    check("a launch context reaches the command", hopped.chrome?.title == "Note from hop")
    await hopped.stop()

    // MARK: OAuth

    let signIn = await started(kitchen, "sign-in", fixture: "kitchen")
    await until { signIn.recorder.finished || signIn.recorder.failure != nil }
    try? await Task.sleep(for: .milliseconds(20))
    check("a sign-in runs to its end", signIn.recorder.finished && signIn.recorder.failure == nil)
    let authorize = signIn.host.log.first { $0.hasPrefix("authorize ") } ?? ""
    let query = URLComponents(string: String(authorize.dropFirst("authorize ".count)).components(separatedBy: " ").first ?? "")?
        .queryItems ?? []
    func item(_ name: String) -> String? { query.first { $0.name == name }?.value }
    check("the request goes to the provider's endpoint", authorize.contains("https://auth.example.com/authorize?"))
    check(
        "with PKCE's S256 challenge and the plugin's redirect",
        item("code_challenge_method") == "S256" && (item("code_challenge")?.count ?? 0) == 43
            && item("redirect_uri") == "tinycast://oauth?plugin=kitchen" && item("client_id") == "kitchen-client"
            && item("prompt") == "consent")
    check("and waits for Tinycast's scheme", authorize.hasSuffix(" tinycast"))
    check(
        "the code comes back and the tokens are kept under the provider",
        signIn.host.tokens["Example"]?.accessToken == "token-for-granted")
    check("they read back, not yet expired", signIn.host.saw("showHUD token-for-granted fresh"))
    let mismatched = TestHost()
    mismatched.redirectQuery = "code=granted&state=forged"
    let forged = await started(kitchen, "sign-in", fixture: "kitchen", host: mismatched)
    await until { forged.recorder.finished || forged.recorder.failure != nil }
    check("a redirect with another state is refused", forged.recorder.failure?.contains("mismatched state") == true)
    let refusedHost = TestHost()
    refusedHost.redirectQuery = "error=access_denied&error_description=The+user+said+no"
    let refusedSignIn = await started(kitchen, "sign-in", fixture: "kitchen", host: refusedHost)
    await until { refusedSignIn.recorder.finished || refusedSignIn.recorder.failure != nil }
    check("the provider's error reaches the plugin", refusedSignIn.recorder.failure?.contains("The user said no") == true)

    // MARK: Failures stay inside the plugin

    let unregistered = manifest(
        plugin(#"name: "fixture", title: "F","#, commands: #".view("cities", title: "C"), .view("missing", title: "M")"#))
    let lost = await launchError(unregistered, "cities", fixture: "cities")
    check("a command main.swift never registered says so", lost?.contains("doesn't register “missing”") == true)
    check("as does one the manifest doesn't declare", lost?.contains("registers “hello”, which Manifest.swift doesn't") == true)
    check(
        "and a command registered as the wrong kind",
        ScriftPluginRuntime.registrationProblems(
            declared: unregistered.commands, registered: ["missing": "view", "cities": "action"]
        ).first?.contains("Plugin.action") == true)

    let broken = manifest(at: "broken")
    let error = await launchError(broken, "one", fixture: "broken")
    check("a type error is reported with its file", error?.contains("main.swift") == true)

    let runaway = manifest(at: "runaway")
    let spin = await started(runaway, "spin", fixture: "runaway")
    let spinStarted = clock.now
    await spin.perform(spin.action("Forever", of: spin.row("Spin")))
    check("an endless loop is stopped", spin.recorder.failure != nil)
    check("within the time limit", clock.now - spinStarted < .seconds(3))

    // MARK: Permissions are APIs

    let gated = manifest(at: "gated")
    let denied = await launchError(gated, "fetch", fixture: "gated")
    check("without the network permission URLSession doesn't exist", denied?.contains("URLSession") == true)
    let granted = manifest(
        plugin(#"name: "gated", title: "G", permissions: [.network],"#, commands: #".action("fetch", title: "F")"#))
    let compiled = Result { () throws(PluginSessionError) in
        _ = try ScriftPluginRuntime.compile(
            plugin: granted, kit: kit, sources: sources("gated"), hostAPI: TestHost(), output: { _ in })
    }
    check("with it the same plugin compiles", (try? compiled.get()) != nil)

    // MARK: What open may reach

    check("a web address opens", PluginOpenTarget.resolve("https://news.ycombinator.com", schemes: []) != nil)
    check("a path opens as a file", PluginOpenTarget.resolve("~/Desktop", schemes: [])?.isFileURL == true)
    check("an undeclared app link doesn't", PluginOpenTarget.resolve("cleanshot://pin", schemes: []) == nil)
    check("a declared one does", PluginOpenTarget.resolve("cleanshot://pin", schemes: ["cleanshot"]) != nil)
    check("no plugin may claim Tinycast's own links", !PluginOpenTarget.isOpenableScheme("tinycast"))
    check("or file URLs", !PluginOpenTarget.isOpenableScheme("FILE"))

    // MARK: The plugin helper, the process the app runs plugin code in

    let helperExecutable = Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "plugin-helper")
    if FileManager.default.isExecutableFile(atPath: helperExecutable.path) {
        let helper = PluginHelperClient(
            executable: helperExecutable,
            cacheDirectory: FileManager.default.temporaryDirectory.appending(path: "plugin-helper-cache-\(UUID())"))
        let remoteStorage = PluginMemoryStorage()
        let remoteStarted = clock.now
        let remote = await started(cities, "cities", fixture: "cities", storage: remoteStorage, helper: helper)
        print("      first launch in the helper \(clock.now - remoteStarted)")
        check("a command runs in the helper", helper.isRunning && remote.list != nil)
        await until { remote.chrome?.isLoading == false }
        check("its task's frame crosses back", remote.section("Cities")?.rows.count == 3)
        check("the same frame as in the app's process", matchesSnapshot(remote.frame, "cities"))
        await remote.search("l")
        check("an event runs there", remote.titles == ["London", "Lima"])
        await remote.perform(remote.action("Pin", of: remote.row("Lima")))
        await until { remoteStorage.value(plugin: "fixture", key: "pinned") != nil }
        check(
            "its storage writes reach the app's storage",
            remoteStorage.value(plugin: "fixture", key: "pinned") == "\"Lima\"")
        check("and it reads back what it wrote", remote.section("Pinned")?.rows.first?.title.plain == "Lima")
        await remote.perform(remote.action("Show", of: remote.section("Cities")?.rows.last))
        check("a push crosses", remote.depth == 2)
        await remote.back()
        check("and so does going back", remote.depth == 1)
        await remote.stop()
        remote.runtime.shutdown()

        let remoteReopened = await started(cities, "cities", fixture: "cities", storage: remoteStorage, helper: helper)
        check("the next launch gets the app's storage", remoteReopened.section("Pinned") != nil)
        let warm = clock.now
        await remoteReopened.stop()
        remoteReopened.runtime.shutdown()
        let again = await started(cities, "cities", fixture: "cities", helper: helper)
        print("      a launch in the warm helper \(clock.now - warm)")
        check("a warm helper launches again", again.list != nil)

        // A crash takes the helper, not the app: the session fails, and the next launch starts another.
        helper.terminate()
        await until(seconds: 5) { again.recorder.failure != nil }
        check("a helper that dies fails its session", again.recorder.failure?.contains("process ended") == true)
        check("and is gone", !helper.isRunning)
        let respawned = await started(cities, "cities", fixture: "cities", helper: helper)
        check("the next launch starts a new helper", helper.isRunning && respawned.list != nil)
        await respawned.stop()
        respawned.runtime.shutdown()

        let remoteLost = await launchError(unregistered, "cities", fixture: "cities", helper: helper)
        check("a launch that fails there says why", remoteLost?.contains("doesn't register “missing”") == true)
        let remoteSpin = await started(runaway, "spin", fixture: "runaway", helper: helper)
        await remoteSpin.perform(remoteSpin.action("Forever", of: remoteSpin.row("Spin")))
        await until(seconds: 5) { remoteSpin.recorder.failure != nil }
        check("an endless loop there is stopped by its limits", remoteSpin.recorder.failure != nil && helper.isRunning)
        remoteSpin.runtime.shutdown()

        let scanned = await helper.scan(examples, description: descriptionDirectory, cache: nil)
        let local = PluginCatalog.scan(examples, description: pluginDescription, cache: nil)
        check("a scan in the helper finds every example", scanned?.map(\.id) == local.map(\.id))
        check("with the same manifests", scanned == local)
        check("the helper reports its footprint", helper.footprint > 0)
        helper.send(.exitWhenIdle)
        await until(seconds: 5) { !helper.isRunning }
        check("an idle helper exits when asked", !helper.isRunning)
    } else {
        print("      (no plugin-helper next to the checks; build the package to check it)")
    }

    // MARK: The CleanShot X example

    let cleanshot = manifest(at: "cleanshot-x")
    let tools = await started(cleanshot, "cleanshot", fixture: "cleanshot-x")
    check(
        "CleanShot X lists its tools",
        tools.screen?.sections.map(\.title) == ["Capture", "Record", "Edit", "Desktop", nil])
    let area = tools.rows.first
    check("a capture offers its five after-capture choices", area?.actions.count == 6)
    check(
        "which open CleanShot's URL API",
        area?.actions.last?.effect == .openURL("cleanshot://capture-area?action=pin", application: nil))
    await tools.stop()
    var opened = true
    for command in cleanshot.commands where command.mode == .action {
        let run = await started(cleanshot, command.name, fixture: "cleanshot-x")
        await until { run.recorder.finished || run.recorder.failure != nil }
        try? await Task.sleep(for: .milliseconds(10))
        if !run.host.saw("open cleanshot://\(command.name)") || run.recorder.failure != nil {
            print("      \(command.name): \(run.host.log) \(run.recorder.failure ?? "")")
            opened = false
        }
    }
    check("every CleanShot X command is registered and opens its link", opened)
    let undeclared = manifest(
        manifestText(examples.appending(path: "cleanshot-x"))
            .replacingOccurrences(of: #"permissions: [.openURLs(schemes: ["cleanshot"])],"#, with: ""))
    check("the example without its grant has no schemes", undeclared.urlSchemes.isEmpty)
    let refused = await started(undeclared, "capture-area", fixture: "cleanshot-x")
    await until { refused.recorder.finished || refused.recorder.failure != nil }
    try? await Task.sleep(for: .milliseconds(10))
    check(
        "without openURLs the same plugin can't open them",
        !refused.host.saw("open ") && refused.host.saw("showHUD This plugin can't open cleanshot"))

    // MARK: The Hacker News example, against the live API

    let hackerNews = manifest(at: "hacker-news")
    let news = await started(hackerNews, "stories", fixture: "hacker-news")
    check("Hacker News opens on the front page", news.chrome?.title == "Front Page")
    await until(seconds: 15) { news.chrome?.isLoading == false }
    if news.list?.emptyState?.title == "Couldn't load stories" {
        print("SKIP  Hacker News is unreachable from here")
    } else {
        check("it loads stories", news.rows.count > 10)
        check("each with points, comments and age", news.rows.first?.accessories.count == 3)
        let primary = news.rows.first?.actions.first.map { $0.children.isEmpty ? [$0] : $0.children }
        check("↵ opens the story, ⌘↵ the comments", primary?.prefix(2).map(\.title) == ["Open Story", "Open Comments"])
        let feed = news.chrome?.pickers.first
        check("the feed is a toolbar picker", feed?.title == "Feed" && feed?.options.count == 4 && feed?.selection == 0)
        if let feed { await news.set(feed.id, .index(1)) }
        check("switching feeds retitles the list", news.chrome?.title == "Newest")
        await until(seconds: 15) { news.chrome?.isLoading == false }
        check("and reloads it", news.rows.count > 10)
        let newest = news.titles
        await news.search("swift")
        await until(seconds: 15) { news.chrome?.isLoading == false && news.titles != newest }
        check("search finds stories", !news.rows.isEmpty)
        check("that match", news.titles.contains { $0.lowercased().contains("swift") })
    }
    await news.stop()
    let top = await started(hackerNews, "top-story", fixture: "hacker-news")
    await until(seconds: 15) { top.menuBar?.isLoading == false }
    check("the top story sits in the menu bar", top.menuBar != nil)
    if top.menuBar?.title != nil {
        check("with its menu of stories", (top.menuBar?.items.count ?? 0) >= 6)
        check("each with an ⌥ alternate", top.menuBar?.items.first?.alternate != nil)
    }
    await top.stop()

    // MARK: The Google Translate example, against the live API

    let translate = manifest(at: "google-translate")
    check("Google Translate declares its seven commands", translate.commands.count == 7)
    let german: [String: PluginValue] = [
        "langFrom": .string("auto"), "lang1": .string("de"), "lang2": .string("fr"), "autoInput": .bool(true),
        "defaultAction": .string("copy"), "prioritizeCrossLanguage": .bool(false)
    ]
    func pair(_ row: PluginRow?) -> String? {
        guard case .text(let text)? = row?.accessories.first else { return nil }
        return text.plain
    }
    let selecting = TestHost()
    selecting.selectedText = "Good morning"
    let translating = await started(
        translate, "translate", fixture: "google-translate", host: selecting, preferences: german)
    await until(seconds: 15) { !translating.rows.isEmpty || translating.host.saw("showToast") }
    if translating.host.saw("showToast") {
        print("SKIP  Google Translate is unreachable from here: \(translating.host.log.last ?? "")")
    } else {
        check("Translate fills its field from the selection", translating.chrome?.search?.text == "Good morning")
        check("and translates it there and back", translating.rows.count == 2 && translating.titles[0].contains("Morgen"))
        check("each row names its pair", pair(translating.rows.first) == "English -> German")
        let actions = translating.rows.first?.actions ?? []
        check("↵ copies the translation", actions.first?.children.first?.title == "Copy Translation")
        check("and the language sets are a ⌘L away", Run.action("Manage Language Sets…", in: actions)?.shortcut?.key == .character("l"))
        await translating.search("Good night")
        await until(seconds: 15) { translating.titles.first?.contains("Nacht") == true }
        check("typing translates again", translating.titles.first?.contains("Nacht") == true)
        let sets = translating.chrome?.pickers.first
        check("the language sets are a toolbar picker", sets?.options.first?.title == "Auto-Detect -> German, French")
        if let sets { await translating.set(sets.id, .index(0)) }
        await until(seconds: 15) { pair(translating.rows.last) == "English -> French" }
        check(
            "a set with two targets translates into each",
            translating.rows.map(pair) == ["English -> German", "English -> French"])
        await translating.stop()

        let form = await started(translate, "translate-form", fixture: "google-translate", preferences: german)
        await form.set("text", .text("Thank you"))
        func translation() -> String? {
            guard case .textEditor(let text, _)? = form.form?.fields.first(where: { $0.id == "result" })?.kind else { return nil }
            return text
        }
        await until(seconds: 15) { translation()?.isEmpty == false }
        check("the form translates its text", translation() == "Danke")
        await form.stop()

        let quick = await started(translate, "quick-translate", fixture: "google-translate", host: selecting)
        await until { quick.recorder.finished || quick.recorder.failure != nil }
        check("Quick Translate hands the selection on", quick.host.saw("launchCommand quick-translate-view"))
        check("as its results' launch text", quick.host.log.contains { $0.contains("Good morning") })
        let results = await started(
            translate, "quick-translate-view", fixture: "google-translate", preferences: german,
            launchContext: ["text": .string("Good morning")])
        await until(seconds: 15) { results.rows.count == 2 }
        check("Quick Translate Results shows each target", results.rows.map(pair) == ["German", "French"])
        check("with the detail open", results.list?.showsDetail == true && results.rows.first?.detail != nil)
        await results.stop()

        let copying = await started(
            translate, "instant-translate-copy", fixture: "google-translate", host: selecting, preferences: german)
        await until(seconds: 15) { copying.recorder.finished || copying.recorder.failure != nil }
        check(
            "Instant Translate Copy copies the translation",
            copying.host.log.contains { $0.hasPrefix("copy ") && $0.contains("Morgen") })
        check("and says so", copying.host.saw("showHUD ✓ Copied To Clipboard"))
        let nothing = await started(translate, "instant-translate-paste", fixture: "google-translate")
        await until { nothing.recorder.finished || nothing.recorder.failure != nil }
        check("with nothing selected it says so", nothing.host.saw("showHUD No text selected"))
    }

    print(failures == 0 ? "All plugin host checks passed." : "\(failures) plugin host checks failed.")
    exit(failures == 0 ? 0 : 1)
}

setvbuf(stdout, nil, _IONBF, 0)
await run()
