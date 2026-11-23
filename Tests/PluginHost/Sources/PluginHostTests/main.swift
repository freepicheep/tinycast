import Foundation
import Scrift

// Drives plugin commands the way the Extensions host does — launch, render, dispatch, pop — with
// the kit and fixtures from this repo, against a host that records every call.

@MainActor
final class TestHost: ExtensionHostAPI {
    var log: [String] = []
    var answers: [String: String] = ["feedback.showToast": "7", "feedback.confirmAlert": "true"]

    /// A provider's tokens as the host keeps them, by provider id.
    var tokens: [String: String] = [:]
    /// What the provider's redirect adds besides the request's state; `code` unless a test says.
    var redirectQuery = "code=granted"

    func perform(api: String, method: String, arguments: [RenderValue]) async throws -> String {
        let shown = arguments.map { $0.stringValue ?? ExtensionJSON.string(from: $0.jsonValue) }
        log.append(([api + "." + method] + shown).joined(separator: " "))
        switch (api, method) {
        case ("oauth", "authorize"):
            // The provider sends the user back to the request's redirect, with its state.
            let request = URLComponents(string: arguments[0].stringValue ?? "")
            let items = request?.queryItems ?? []
            let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
            let state = items.first { $0.name == "state" }?.value ?? ""
            let separator = redirect.contains("?") ? "&" : "?"
            return redirect + separator + redirectQuery + "&state=" + state
        case ("oauth", "setTokens"):
            tokens[arguments[0].stringValue ?? ""] = arguments[1].stringValue
            return ""
        case ("oauth", "getTokens"):
            return tokens[arguments[0].stringValue ?? ""] ?? ""
        default:
            return answers[api + "." + method] ?? ""
        }
    }

    func sessionEnded() {}

    func saw(_ prefix: String) -> Bool { log.contains { $0.hasPrefix(prefix) } }
}

/// What the runtime told the host, as the palette would have drawn it.
@MainActor
final class Recorder: ExtensionRuntimeDelegate {
    var tree: RenderTree?
    var failure: String?
    var finished = false
    var renders = 0

    func runtime(_ runtime: any ExtensionCommandRuntime, session: String, didRender tree: RenderTree) {
        self.tree = tree
        renders += 1
    }
    func runtime(_ runtime: any ExtensionCommandRuntime, session: String, didFail message: String) {
        failure = message
    }
    func runtime(_ runtime: any ExtensionCommandRuntime, session: String, navigationDepth: Int) {}
    func runtime(_ runtime: any ExtensionCommandRuntime, session: String, didFinish: Void) {
        finished = true
    }
    func runtime(_ runtime: any ExtensionCommandRuntime, log level: String, message: String) {}
}

/// One launched command.
@MainActor
final class Run {
    let runtime: ScriftPluginRuntime
    let recorder = Recorder()
    let host: TestHost
    let session = "s"

    init(runtime: ScriftPluginRuntime, host: TestHost) {
        self.runtime = runtime
        self.host = host
        runtime.setDelegate(recorder)
    }

    var root: RenderNode? { recorder.tree?.activeRoot }
    var depth: Int { recorder.tree?.depth ?? 0 }

    /// The first node of `type` in the screen, by `title` when given.
    func find(_ type: String, _ title: String? = nil) -> RenderNode? {
        root.flatMap { Self.find(type, title, in: $0) }
    }

    static func find(_ type: String, _ title: String?, in node: RenderNode) -> RenderNode? {
        if node.type == type, title == nil || node.string("title") == title { return node }
        for child in node.children {
            if let hit = find(type, title, in: child) { return hit }
        }
        for value in node.props.values {
            for nested in value.nodesValue {
                if let hit = find(type, title, in: nested) { return hit }
            }
        }
        return nil
    }

    func all(_ type: String) -> [RenderNode] {
        var found: [RenderNode] = []
        func walk(_ node: RenderNode) {
            if node.type == type { found.append(node) }
            node.children.forEach(walk)
        }
        root.map(walk)
        return found
    }

    /// Runs a handler prop the way the palette does, with JSON arguments.
    func fire(_ node: RenderNode?, _ prop: String = "onAction", _ arguments: [Any] = []) async {
        guard let id = node?.handler(prop) else {
            print("      (no \(prop) handler on \(node?.type ?? "nothing"))")
            return
        }
        await runtime.dispatch(
            session: session, handler: id, payload: ExtensionJSON.string(from: arguments), completesSession: false)
    }

    /// The action titled `title` in a node's action panel.
    func action(_ title: String, of node: RenderNode?) -> RenderNode? {
        guard let panel = node?.node("actions") else { return nil }
        return Self.find("Action", title, in: panel)
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

@MainActor func freshStorage() -> ExtensionStorage {
    ExtensionStorage(directory: FileManager.default.temporaryDirectory.appending(path: "plugin-storage-\(UUID())"))
}

/// Launches one of `manifest`'s commands from the plugin in `fixture` (its folder name).
@MainActor func launch(
    _ manifest: PluginManifest, _ command: String, fixture: String, storage: ExtensionStorage = freshStorage(),
    host: TestHost = TestHost(), arguments: [String: String] = [:],
    preferences: [String: ExtensionPreferenceValue] = [:], launchType: ExtensionLaunchType = .userInitiated,
    launchContext: [String: RenderValue] = [:]
) async throws -> Run {
    let runtime = ScriftPluginRuntime(
        plugin: manifest, directory: folder(fixture), storage: storage, hostAPI: host, appScheme: "tinycast",
        kitSources: { kit })
    let run = Run(runtime: runtime, host: host)
    guard let extensionManifest = manifest.extensionManifest(),
        let declared = extensionManifest.commands.first(where: { $0.name == command })
    else { throw PluginSessionError.internal("no command \(command)") }
    let owner = InstalledExtension(manifest: extensionManifest, directory: folder(fixture), engine: .plugin)
    let context = ExtensionLaunchContext(
        extensionName: manifest.hostName, extensionTitle: manifest.title, commandName: command,
        commandMode: declared.mode, assetsPath: "", supportPath: "", preferences: preferences, caches: [:],
        arguments: arguments, launchType: launchType, isDarkAppearance: false, launchContext: launchContext)
    try await runtime.launch(session: run.session, owner: owner, command: declared, context: context)
    return run
}

@MainActor func started(
    _ manifest: PluginManifest, _ command: String, fixture: String, storage: ExtensionStorage = freshStorage(),
    host: TestHost = TestHost(), arguments: [String: String] = [:],
    preferences: [String: ExtensionPreferenceValue] = [:], launchType: ExtensionLaunchType = .userInitiated,
    launchContext: [String: RenderValue] = [:]
) async -> Run {
    do {
        return try await launch(
            manifest, command, fixture: fixture, storage: storage, host: host, arguments: arguments,
            preferences: preferences, launchType: launchType, launchContext: launchContext)
    } catch {
        print("FAIL  launch \(command): \(error.localizedDescription)")
        exit(1)
    }
}

/// Why launching fails, or nil when it doesn't.
@MainActor func launchError(_ manifest: PluginManifest, _ command: String, fixture: String) async -> String? {
    do {
        let run = try await launch(manifest, command, fixture: fixture)
        await run.stop()
        return nil
    } catch {
        return error.localizedDescription
    }
}

@MainActor func until(seconds: Int = 2, _ condition: () -> Bool) async {
    for _ in 0..<(seconds * 100) where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
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

    // MARK: What the Extensions host sees

    let kitchen = manifest(at: "kitchen")
    let host = kitchen.extensionManifest()
    check("a plugin joins the host under a dotted name", host?.name == "plugin.kitchen")
    check("its commands keep their modes", host?.commands.map(\.mode) == [.view, .view, .menuBar, .noView, .noView, .noView])
    check("a menu bar interval crosses", host?.commands[2].interval != nil)
    check("arguments cross", host?.commands[0].arguments.map(\.name) == ["subject"])
    check("and the plugin's preferences", host?.preferences.map(\.name) == ["greeting", "loud"])
    check("the JSON form keeps the new fields", (try? PluginManifest.decode(kitchen.json())) == kitchen)

    // MARK: A view command, end to end

    let cities = manifest(at: "cities")
    let clock = ContinuousClock()
    let storage = freshStorage()
    let started0 = clock.now
    let session = await started(cities, "cities", fixture: "cities", storage: storage)
    print("      first launch \(clock.now - started0)")
    check("the list renders on launch", session.root?.type == "List")
    check("loading at first", session.root?.bool("isLoading") == true)
    check("with its title", session.root?.string("navigationTitle") == "Cities")
    check("and its prompt", session.root?.string("searchBarPlaceholder") == "Filter cities")
    check("a list with its own search isn't filtered by Tinycast", session.root?.bool("filtering") == false)
    await until { session.root?.bool("isLoading") == false }
    check("its task loads the rows", session.find("List.Section", "Cities")?.children.count == 3)

    await session.fire(session.root, "onSearchTextChange", ["l"])
    let rows = session.find("List.Section", "Cities")?.children ?? []
    check("typing filters through the binding", rows.map { $0.string("title") } == ["London", "Lima"])
    check("the binding reads back what was typed", session.root?.string("searchText") == "l")

    let lima = rows.last
    check("a row has its badge", lima?.array("accessories").first?.objectValue?["text"]?.stringValue == "4")
    check(
        "and its symbol",
        lima?.object("icon")?["source"]?.objectValue?["systemImage"]?.stringValue == "building.2")
    let copy = session.action("Copy to Clipboard", of: lima)
    check("copy is the first action", lima?.node("actions")?.children.first?.string("title") == "Copy to Clipboard")
    await session.fire(copy)
    await session.runtime.drainHostCalls()
    try? await Task.sleep(for: .milliseconds(20))
    check("copying reaches the clipboard", session.host.saw("clipboard.copy {\"text\":\"Lima\"}"))
    check("closes the palette and says so", session.host.saw("window.close") && session.host.saw("feedback.showHUD Copied"))
    let pin = session.action("Pin", of: lima)
    check("a declared shortcut crosses", pin?.object("shortcut")?["key"]?.stringValue == "p")
    check(
        "with Raycast's modifier names",
        pin?.object("shortcut")?["modifiers"]?.arrayValue?.compactMap(\.stringValue) == ["cmd", "shift"])
    await session.fire(pin)
    check(
        "@AppStorage writes the plugin's storage",
        storage.localStorageValue(extension: "plugin.fixture", key: "pinned") == .string("Lima"))
    check("and the list shows the pin", session.all("List.Section").first?.string("title") == "Pinned")
    let pinnedRow = session.find("List.Section", "Pinned")?.children.first
    check("tinted", pinnedRow?.object("icon")?["tintColor"]?.stringValue == "raycast-orange")

    let limaAgain = session.find("List.Section", "Cities")?.children.last
    await session.fire(session.action("Show", of: limaAgain))
    check("a NavigationLink pushes its view", session.root?.string("markdown")?.contains("Lima") == true)
    check("onto the host's stack", session.depth == 2)
    let visit = session.action("Visit", of: session.root)
    await session.fire(visit)
    await session.fire(session.action("Visit", of: session.root))
    check("a pushed view keeps its @State", session.root?.string("markdown")?.contains("Visited 2 times") == true)
    let label = session.find("Detail.Metadata.Label", "Country")
    check("metadata crosses", label?.string("text") == "Peru")
    let popped = await session.runtime.popNavigation(session: session.session)
    try? await Task.sleep(for: .milliseconds(20))
    check("going back returns to the list", popped && session.root?.type == "List" && session.depth == 1)
    let rootPop = await session.runtime.popNavigation(session: session.session)
    check("the root can't go back", !rootPop)
    let ids = session.all("List.Item").map(\.id)
    check("node ids are stable and distinct", Set(ids).count == ids.count && ids.allSatisfy { $0 > 1024 })
    await session.stop()

    // MARK: Storage outlives the session

    let reopened = await started(cities, "cities", fixture: "cities", storage: storage)
    check("a new session reads the stored pin", reopened.find("List.Section", "Pinned")?.children.first?.string("title") == "Lima")
    await reopened.stop()

    // MARK: An action command

    let warm = clock.now
    let hello = await started(cities, "hello", fixture: "cities")
    print("      warm launch \(clock.now - warm)")
    await until { hello.recorder.finished || hello.recorder.failure != nil }
    check("an action command finishes", hello.recorder.finished)
    try? await Task.sleep(for: .milliseconds(20))
    check("and its HUD reaches the host", hello.host.saw("feedback.showHUD Hello from hello"))

    // MARK: Forms

    let note = await started(kitchen, "note", fixture: "kitchen", arguments: ["subject": "Groceries"])
    check("a form renders", note.root?.type == "Form")
    let subject = note.find("Form.TextField", "Subject")
    check("an argument reaches the command", subject?.string("value") == "Groceries")
    check("with its placeholder", subject?.string("placeholder") == "What about?")
    check("a field's id defaults to its title", subject?.string("id") == "Subject")
    await note.fire(subject, "onTinycastChange", ["Milk"])
    check("a change writes the binding", note.find("Form.TextField", "Subject")?.string("value") == "Milk")
    await note.fire(note.find("Form.Dropdown", "Kind"), "onTinycastChange", ["task"])
    await note.fire(note.find("Form.TagPicker", "Tags"), "onTinycastChange", [["home", "work"]])
    await note.fire(note.find("Form.Checkbox", "Urgent"), "onTinycastChange", [true])
    check("a checkbox toggles", note.find("Form.Checkbox", "Urgent")?.bool("value") == true)
    check(
        "a dropdown's choices take the form's names",
        note.find("Form.Dropdown", "Kind")?.children.map(\.type) == ["Form.Dropdown.Item", "Form.Dropdown.Item"])
    await note.fire(note.find("Form.DatePicker", "Due"), "onTinycastChange", [["$date": "2026-12-24T10:00:00Z"]])
    check("a date crosses", note.find("Form.DatePicker", "Due")?.date("value") != nil)
    check("a divider becomes the form's separator", note.find("Form.Separator") != nil)
    await note.fire(note.action("Save", of: note.root))
    check(
        "submit runs with the form's values",
        note.find("Form.Description", "Status")?.string("text") == "Saved Milk task home,work")
    await note.stop()
    let kitchenStorage = freshStorage()
    let first = await started(kitchen, "note", fixture: "kitchen", storage: kitchenStorage)
    await first.fire(first.find("Form.TextField", "Subject"), "onTinycastChange", ["Remembered"])
    await first.fire(first.action("Save", of: first.root))
    check(
        "a stored field is saved for the command",
        kitchenStorage.formValues(extension: "plugin.kitchen", command: "note")["Subject"] == "Remembered")
    await first.stop()
    let second = await started(kitchen, "note", fixture: "kitchen", storage: kitchenStorage)
    check("and the next launch starts from it", second.find("Form.TextField", "Subject")?.string("value") == "Remembered")
    await second.stop()

    // MARK: Grids and the search bar's dropdown

    let colors = await started(kitchen, "colors", fixture: "kitchen", storage: kitchenStorage)
    check("a grid renders", colors.root?.type == "Grid" && colors.root?.double("columns") == 4)
    let tiles = colors.find("Grid.Section", "Swatches")?.children ?? []
    check("its items are grid items", tiles.map(\.type) == ["Grid.Item", "Grid.Item", "Grid.Item"])
    check("a colour tile is a swatch", tiles.first?.object("content")?["color"]?.stringValue == "raycast-red")
    check("a symbol becomes the tile's content", tiles.dropFirst().first?.props["content"] != nil)
    let dropdown = colors.root?.node("searchBarAccessory")
    check("the dropdown sits beside the search", dropdown?.type == "Grid.Dropdown" && dropdown?.children.count == 2)
    await colors.fire(dropdown, "onChange", ["cool"])
    check(
        "choosing writes @AppStorage",
        kitchenStorage.localStorageValue(extension: "plugin.kitchen", key: "palette") == .string("cool")
            && colors.find("Grid.Section", "Swatches")?.children.last?.string("title") == "Ice")
    await colors.stop()

    // MARK: Menu bar commands

    let status = await started(kitchen, "status", fixture: "kitchen")
    check("a menu bar command renders its extra", status.root?.type == "MenuBarExtra" && status.root?.string("title") == "0")
    let add = status.find("MenuBarExtra.Item", "Add")
    check("its items have shortcuts", add?.object("shortcut")?["modifiers"]?.arrayValue?.first?.stringValue == "cmd")
    await status.fire(add)
    check("an item's action renders again", status.root?.string("title") == "1")
    check(
        "sections, submenus and separators take the menu's names",
        status.find("MenuBarExtra.Section", "More") != nil && status.find("MenuBarExtra.Submenu", "Reset") != nil
            && status.find("MenuBarExtra.Separator") != nil)
    await status.stop()

    // MARK: Preferences, toasts and launching commands

    let toast = await started(
        kitchen, "toast", fixture: "kitchen", preferences: ["greeting": .string("Howdy"), "loud": .bool(true)],
        launchType: .background)
    await until { toast.recorder.finished || toast.recorder.failure != nil }
    try? await Task.sleep(for: .milliseconds(30))
    check("an action command reads its preferences", toast.host.saw("feedback.showToast {") && toast.host.log.contains { $0.contains("HOWDY") })
    check("a toast changes after it shows", toast.host.log.contains { $0.hasPrefix("feedback.updateToast 7") && $0.contains("background") })
    let update = toast.host.log.last { $0.hasPrefix("feedback.updateToast") }
    let token = update.flatMap { line in
        line.range(of: "plugin-toast-[0-9]+", options: .regularExpression).map { String(line[$0]) }
    }
    check("its button is a token for the script's closure", token != nil)
    if let token { await toast.runtime.runToastAction(token: token) }
    try? await Task.sleep(for: .milliseconds(30))
    check("which runs it", toast.host.saw("feedback.showHUD Undone"))

    let hop = await started(kitchen, "hop", fixture: "kitchen")
    await until { hop.recorder.finished || hop.recorder.failure != nil }
    try? await Task.sleep(for: .milliseconds(20))
    check("launchCommand asks the host", hop.host.log.contains {
        $0.hasPrefix("system.launchCommand") && $0.contains("\"name\":\"note\"") && $0.contains("From hop")
    })
    let hopped = await started(
        kitchen, "note", fixture: "kitchen", arguments: ["subject": "From hop"], launchContext: ["origin": .string("hop")])
    check("a launch context reaches the command", hopped.root?.string("navigationTitle") == "Note from hop")
    await hopped.stop()

    // MARK: OAuth

    let signIn = await started(kitchen, "sign-in", fixture: "kitchen")
    await until { signIn.recorder.finished || signIn.recorder.failure != nil }
    try? await Task.sleep(for: .milliseconds(20))
    check("a sign-in runs to its end", signIn.recorder.finished && signIn.recorder.failure == nil)
    let authorize = signIn.host.log.first { $0.hasPrefix("oauth.authorize") } ?? ""
    let query = URLComponents(string: String(authorize.dropFirst("oauth.authorize ".count)).components(separatedBy: " ").first ?? "")?
        .queryItems ?? []
    func item(_ name: String) -> String? { query.first { $0.name == name }?.value }
    check("the request goes to the provider's endpoint", authorize.contains("https://auth.example.com/authorize?"))
    check(
        "with PKCE's S256 challenge and the plugin's redirect",
        item("code_challenge_method") == "S256" && (item("code_challenge")?.count ?? 0) == 43
            && item("redirect_uri") == "tinycast://oauth?plugin=kitchen" && item("client_id") == "kitchen-client"
            && item("prompt") == "consent")
    check("and waits for Tinycast's scheme", authorize.hasSuffix(" tinycast"))
    check("the code comes back and the tokens are kept under the provider", signIn.host.tokens["Example"]?.contains("token-for-granted") == true)
    check("they read back, not yet expired", signIn.host.saw("feedback.showHUD token-for-granted fresh"))
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
            declared: unregistered.commands, registered: ["missing": "view", "cities": "no-view"]
        ).first?.contains("Plugin.action") == true)

    let broken = manifest(at: "broken")
    let error = await launchError(broken, "one", fixture: "broken")
    check("a type error is reported with its file", error?.contains("main.swift") == true)

    let runaway = manifest(at: "runaway")
    let spin = await started(runaway, "spin", fixture: "runaway")
    let spinStarted = clock.now
    await spin.fire(spin.action("Forever", of: spin.find("List.Item", "Spin")))
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

    // MARK: The CleanShot X example

    let cleanshot = manifest(at: "cleanshot-x")
    let tools = await started(cleanshot, "cleanshot", fixture: "cleanshot-x")
    let titles = tools.all("List.Section").map { $0.string("title") }
    check("CleanShot X lists its tools", titles == ["Capture", "Record", "Edit", "Desktop", nil])
    let area = tools.all("List.Item").first
    check("a capture offers its five after-capture choices", (area?.node("actions")?.children.count ?? 0) >= 5)
    if let last = area?.node("actions")?.children.last { await tools.fire(last) }
    try? await Task.sleep(for: .milliseconds(20))
    check("which open CleanShot's URL API", tools.host.saw("system.open cleanshot://capture-area?action="))
    await tools.stop()
    var opened = true
    for command in cleanshot.commands where command.mode == .action {
        let run = await started(cleanshot, command.name, fixture: "cleanshot-x")
        await until { run.recorder.finished || run.recorder.failure != nil }
        try? await Task.sleep(for: .milliseconds(10))
        if !run.host.saw("system.open cleanshot://\(command.name)") || run.recorder.failure != nil {
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
        !refused.host.saw("system.open") && refused.host.saw("feedback.showHUD This plugin can't open cleanshot"))

    // MARK: The Hacker News example, against the live API

    let hackerNews = manifest(at: "hacker-news")
    let newsStorage = freshStorage()
    let news = await started(hackerNews, "stories", fixture: "hacker-news", storage: newsStorage)
    check("Hacker News opens on the front page", news.root?.string("navigationTitle") == "Front Page")
    await until(seconds: 15) { news.root?.bool("isLoading") == false }
    let stories = news.all("List.Item")
    if news.find("List.EmptyView")?.string("title") == "Couldn't load stories" {
        print("SKIP  Hacker News is unreachable from here")
    } else {
        check("it loads stories", stories.count > 10)
        check("each with points, comments and age", stories.first?.array("accessories").count == 3)
        let firstTwo = stories.first?.node("actions")?.children.prefix(2).map { $0.string("title") }
        check("↵ opens the story, ⌘↵ the comments", firstTwo == ["Open Story", "Open Comments"])
        let feed = news.root?.node("searchBarAccessory")
        await news.fire(feed, "onChange", ["newest"])
        check("switching feeds retitles the list", news.root?.string("navigationTitle") == "Newest")
        await until(seconds: 15) { news.root?.bool("isLoading") == false }
        check("and reloads it", news.all("List.Item").count > 10)
        let newest = news.all("List.Item").map { $0.string("title") }
        await news.fire(news.root, "onSearchTextChange", ["swift"])
        await until(seconds: 15) {
            news.root?.bool("isLoading") == false && news.all("List.Item").map { $0.string("title") } != newest
        }
        let found = news.all("List.Item")
        check("search finds stories", !found.isEmpty)
        check("that match", found.contains { $0.string("title")?.lowercased().contains("swift") == true })
    }
    await news.stop()
    let top = await started(hackerNews, "top-story", fixture: "hacker-news")
    await until(seconds: 15) { top.root?.bool("isLoading") == false }
    check("the top story sits in the menu bar", top.root?.type == "MenuBarExtra")
    if top.root?.string("title") != nil {
        check("with its menu of stories", top.all("MenuBarExtra.Item").count >= 6)
        check("each with an ⌥ alternate", top.all("MenuBarExtra.Item").first?.node("alternate") != nil)
    }
    await top.stop()

    print(failures == 0 ? "All plugin host checks passed." : "\(failures) plugin host checks failed.")
    exit(failures == 0 ? 0 : 1)
}

setvbuf(stdout, nil, _IONBF, 0)
await run()
