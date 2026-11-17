import Foundation
import Stir

// Drives plugin sessions the way the palette does, with the kit and fixtures from this repo.

@MainActor
final class Services: PluginHostServices {
    var log: [String] = []
    func showHUD(_ text: String) { log.append("hud: \(text)") }
    func closeWindow() { log.append("close") }
    func copy(_ text: String) { log.append("copy: \(text)") }
    func paste(_ text: String) { log.append("paste: \(text)") }
    func open(_ url: URL) { log.append("open: \(url.absoluteString)") }
    func refuseOpen(_ target: String) { log.append("refused: \(target)") }
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

@MainActor func manifest(at name: String) -> PluginManifest {
    manifest(manifestText(fixtures.appending(path: name)))
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
    let folder = FileManager.default.fileExists(atPath: fixtures.appending(path: name).path)
        ? fixtures.appending(path: name) : examples.appending(path: name)
    return must("read \(name)'s sources") { try PluginSources.read(from: folder) }
}

@MainActor func example(_ name: String) -> PluginManifest {
    manifest(manifestText(examples.appending(path: name)))
}


/// A session for one of `manifest`'s commands, built from a fixture's sources.
@MainActor func launch(
    _ manifest: PluginManifest, command: Int = 0, fixture: String, kit: PluginSources,
    storage: PluginStorage = freshStorage(), services: Services = Services()
) -> PluginSession {
    must("load \(fixture)") {
        try PluginSession(
            manifest: manifest, command: manifest.commands[command], sources: sources(fixture), kit: kit,
            storage: storage, services: services)
    }
}

@MainActor func freshStorage(at url: URL = scratchFile()) -> PluginStorage {
    PluginStorage(fileURL: url)
}

func scratchFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "plugin-\(UUID()).json")
}

@MainActor func perform(_ action: PluginAction, in session: PluginSession, services: Services) {
    switch action.kind {
    case .perform(let body): session.call { try body() }
    case .copy(let text): services.copy(text)
    case .paste(let text): services.paste(text)
    case .open(let target): session.open(target)
    }
}

@MainActor func list(_ session: PluginSession) -> PluginList? {
    if case .running(.list(let list)) = session.state { return list }
    return nil
}

@MainActor func detail(_ session: PluginSession) -> PluginDetail? {
    if case .running(.detail(let detail)) = session.state { return detail }
    return nil
}

@MainActor func failure(_ session: PluginSession) -> String? {
    if case .failed(let message) = session.state { return message }
    return nil
}

@MainActor func compileError(_ manifest: PluginManifest, _ fixture: String, kit: PluginSources) -> String? {
    do {
        _ = try PluginSession(
            manifest: manifest, command: manifest.commands[0], sources: sources(fixture), kit: kit,
            storage: freshStorage(), services: Services())
        return nil
    } catch {
        return error.description
    }
}

@MainActor func until(seconds: Int = 2, _ condition: () -> Bool) async {
    for _ in 0..<(seconds * 100) where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor func run() async {
    let kit = must("read the kit") { try PluginSources.read(from: kitDirectory, requiringMain: false) }
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

    // MARK: A view command, end to end

    let cities = manifest(at: "cities")
    let services = Services()
    let storageFile = scratchFile()
    let storage = freshStorage(at: storageFile)
    let clock = ContinuousClock()
    let started = clock.now
    let session = launch(cities, fixture: "cities", kit: kit, storage: storage, services: services)
    print("      first load \(clock.now - started)")
    await session.open()
    check("the list opens loading", list(session)?.isLoading == true)
    check("the list keeps its title", list(session)?.title == "Cities")
    check("and its prompt", list(session)?.searchPrompt == "Filter cities")
    await until { list(session)?.isLoading == false }
    check("its task loads the rows", list(session)?.sections.last?.items.count == 3)

    session.call { try list(session)?.search?.onChange("l") }
    check("typing filters through the binding", list(session)?.sections.last?.items.map(\.title) == ["London", "Lima"])
    check("the binding reads back what was typed", list(session)?.search?.text == "l")

    let lima = list(session)!.sections.last!.items.first { $0.title == "Lima" }!
    check("a row has its badge", lima.badges == ["4"])
    if case .symbol("building.2", nil) = lima.icon { check("and its symbol", true) } else { check("and its symbol", false) }
    if case .copy("Lima") = lima.actions[0].kind {
        check("copy is the first action, unhandled by the script", true)
    } else {
        check("copy is the first action, unhandled by the script", false)
    }
    check("a declared shortcut crosses", lima.actions[1].shortcutKey == "p")
    check("with its modifiers", Set(lima.actions[1].modifiers) == ["command", "shift"])
    perform(lima.actions[1], in: session, services: services)
    check("@AppStorage writes the plugin's storage", storage.value(forKey: "pinned") == "Lima")
    check("and the list shows the pin", list(session)?.sections.first?.title == "Pinned")

    perform(lima.actions[2], in: session, services: services)
    check("a NavigationLink pushes its view", detail(session)?.markdown.contains("Lima") == true)
    check("onto the plugin's own stack", session.navigationDepth == 2)
    perform(detail(session)!.actions[0], in: session, services: services)
    perform(detail(session)!.actions[0], in: session, services: services)
    check("a pushed view keeps its @State", detail(session)?.markdown.contains("Visited 2 times") == true)
    check("metadata crosses", detail(session)?.metadata.first?.value == "Peru")
    check("going back returns to the list", session.goBack() && list(session) != nil && session.navigationDepth == 1)
    check("the root can't go back", !session.goBack())
    session.close()

    // MARK: Storage outlives the session

    let reopened = launch(cities, fixture: "cities", kit: kit, storage: freshStorage(at: storageFile), services: services)
    await reopened.open()
    check("a new session reads the stored pin", list(reopened)?.sections.first?.items.first?.title == "Lima")
    reopened.close()

    // MARK: An action command

    let warm = clock.now
    let action = launch(cities, command: 1, fixture: "cities", kit: kit, services: services)
    print("      cached load \(clock.now - warm)")
    await action.run()
    check("an action command finishes", { if case .finished = action.state { return true }; return false }())
    check("and its HUD reaches the host", services.log.last == "hud: Hello from hello")

    // MARK: Failures stay inside the plugin

    let unregistered = manifest(
        plugin(#"name: "fixture", title: "F","#, commands: #".view("cities", title: "C"), .view("missing", title: "M")"#))
    let lost = compileError(unregistered, "cities", kit: kit)
    check("a command main.swift never registered says so", lost?.contains("doesn't register “missing”") == true)
    check("as does one the manifest doesn't declare", lost?.contains("registers “hello”, which Manifest.swift doesn't") == true)
    check(
        "and a command registered as the wrong kind",
        PluginSession.registrationProblems(
            declared: unregistered.commands, views: ["missing"], actions: ["cities"]).first?.contains("Plugin.action") == true)

    let broken = manifest(at: "broken")
    let error = compileError(broken, "broken", kit: kit)
    check("a type error is reported with its file", error?.contains("main.swift") == true)

    let runaway = manifest(at: "runaway")
    let spin = launch(runaway, fixture: "runaway", kit: kit, services: services)
    await spin.open()
    let spinStarted = clock.now
    perform(list(spin)!.sections[0].items[0].actions[0], in: spin, services: services)
    check("an endless loop is stopped", failure(spin) != nil)
    check("within the time limit", clock.now - spinStarted < .seconds(3))
    spin.close()

    // MARK: Permissions are APIs

    let gated = manifest(at: "gated")
    let denied = compileError(gated, "gated", kit: kit)
    check("without the network permission URLSession doesn't exist", denied?.contains("URLSession") == true)
    let granted = manifest(
        plugin(#"name: "gated", title: "G", permissions: [.network],"#, commands: #".action("fetch", title: "F")"#))
    check("with it the same plugin compiles", compileError(granted, "gated", kit: kit) == nil)

    // MARK: What open may reach

    check("a web address opens", PluginOpenTarget.resolve("https://news.ycombinator.com", schemes: []) != nil)
    check("a path opens as a file", PluginOpenTarget.resolve("~/Desktop", schemes: [])?.isFileURL == true)
    check("an undeclared app link doesn't", PluginOpenTarget.resolve("cleanshot://pin", schemes: []) == nil)
    check("a declared one does", PluginOpenTarget.resolve("cleanshot://pin", schemes: ["cleanshot"]) != nil)
    check("no plugin may claim Tinycast's own links", !PluginOpenTarget.isOpenableScheme("tinycast"))
    check("or file URLs", !PluginOpenTarget.isOpenableScheme("FILE"))

    // MARK: The CleanShot X example

    let cleanshot = example("cleanshot-x")
    let shots = Services()
    let tools = launch(cleanshot, fixture: "cleanshot-x", kit: kit, services: shots)
    await tools.open()
    let titles = list(tools)?.sections.map(\.title)
    check("CleanShot X lists its tools", titles == ["Capture", "Record", "Edit", "Desktop", nil])
    let area = list(tools)?.sections.first?.items.first
    check("a capture offers its five after-capture choices", area?.actions.count == 6)
    if let action = area?.actions.last { perform(action, in: tools, services: shots) }
    check("which open CleanShot's URL API", shots.log.last == "open: cleanshot://capture-area?action=pin")
    tools.close()
    for (index, command) in cleanshot.commands.enumerated() where command.mode == .action {
        let session = launch(cleanshot, command: index, fixture: "cleanshot-x", kit: kit, services: shots)
        await session.run()
        let expected = command.name == "open-settings" ? "open-settings" : command.name
        if shots.log.last != "open: cleanshot://\(expected)" || failure(session) != nil {
            check("the \(command.name) command opens its link", false)
        }
    }
    check("every CleanShot X command is registered and opens its link", true)
    let undeclared = manifest(
        manifestText(examples.appending(path: "cleanshot-x"))
            .replacingOccurrences(of: #"permissions: [.openURLs(schemes: ["cleanshot"])],"#, with: ""))
    check("the example without its grant has no schemes", undeclared.urlSchemes.isEmpty)
    let areaIndex = undeclared.commands.firstIndex { $0.name == "capture-area" } ?? 0
    let refused = launch(undeclared, command: areaIndex, fixture: "cleanshot-x", kit: kit, services: shots)
    await refused.run()
    check("without openURLs the same plugin can't open them", shots.log.last == "refused: cleanshot://capture-area")

    // MARK: The Hacker News example, against the live API

    let hackerNews = example("hacker-news")
    let news = launch(hackerNews, fixture: "hacker-news", kit: kit)
    await news.open()
    check("Hacker News opens on the front page", list(news)?.title == "Front Page")
    await until(seconds: 15) { list(news)?.isLoading == false }
    let stories = list(news)?.sections.first?.items ?? []
    if list(news)?.emptyText == "Couldn't load stories" {
        print("SKIP  Hacker News is unreachable from here: \(news.output)")
    } else {
        check("it loads stories", stories.count > 10)
        check("each with points, comments and age", stories.first?.badges.count == 3)
        let firstTwo = stories.first?.actions.prefix(2).map(\.title)
        check("↵ opens the story, ⌘↵ the comments", firstTwo == ["Open Story", "Open Comments"])
        if let switchFeed = stories.first?.actions.first(where: { $0.title == "Show Newest" }) {
            perform(switchFeed, in: news, services: Services())
        }
        check("switching feeds retitles the list", list(news)?.title == "Newest")
        await until(seconds: 15) { list(news)?.isLoading == false }
        check("and reloads it", (list(news)?.sections.first?.items.count ?? 0) > 10)
        let newest = list(news)?.sections.first?.items.map(\.title) ?? []
        news.call { try list(news)?.search?.onChange("swift") }
        // The search's own task sets loading only once it starts, so wait for its rows instead.
        await until(seconds: 15) {
            list(news)?.isLoading == false && list(news)?.sections.first?.items.map(\.title) != newest
        }
        let found = list(news)?.sections.first?.items ?? []
        check("search finds stories", !found.isEmpty)
        check("that match", found.contains { $0.title.lowercased().contains("swift") })
        if failures > 0 { print(news.output) }
    }
    news.close()

    print(failures == 0 ? "All plugin host checks passed." : "\(failures) plugin host checks failed.")
    exit(failures == 0 ? 0 : 1)
}

setvbuf(stdout, nil, _IONBF, 0)
await run()
