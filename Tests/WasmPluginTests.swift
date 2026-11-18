import Foundation

/// Plugins built with the Swift SDK for WebAssembly, run through the shipped runtime against a
/// host that records every call. `Scripts/test-plugins.sh` builds the fixture and the examples
/// into the folder this takes as its argument.

@MainActor
final class TestHost: ExtensionHostAPI {
    var log: [String] = []
    var storage: [String: Any] = [:]
    var tokens: [String: String] = [:]
    var answers: [String: String] = [
        "feedback.showToast": "7", "feedback.confirmAlert": "true",
        "clipboard.readText": "\"clip\""
    ]
    var redirectQuery = "code=granted"

    func perform(api: String, method: String, arguments: [RenderValue]) async throws -> String {
        let shown = arguments.map { $0.stringValue ?? ExtensionJSON.string(from: $0.jsonValue) }
        log.append(([api + "." + method] + shown).joined(separator: " "))
        switch (api, method) {
        case ("storage", "all"): return ExtensionJSON.string(from: storage)
        case ("storage", "set"):
            storage[arguments[0].stringValue ?? ""] = arguments[1].jsonValue
            return "null"
        case ("oauth", "authorize"):
            let items = URLComponents(string: arguments[0].stringValue ?? "")?.queryItems ?? []
            let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
            let state = items.first { $0.name == "state" }?.value ?? ""
            let separator = redirect.contains("?") ? "&" : "?"
            return ExtensionJSON.string(from: redirect + separator + redirectQuery + "&state=" + state)
        case ("oauth", "setTokens"):
            tokens[arguments[0].stringValue ?? ""] = arguments[1].stringValue
            return "null"
        case ("oauth", "getTokens"):
            return ExtensionJSON.string(from: tokens[arguments[0].stringValue ?? ""] ?? NSNull())
        default:
            return answers[api + "." + method] ?? "null"
        }
    }

    func sessionEnded() { log.append("sessionEnded") }

    func saw(_ prefix: String) -> Bool { log.contains { $0.hasPrefix(prefix) } }
}

@MainActor
final class Recorder: ExtensionRuntimeDelegate {
    var trees: [RenderTree] = []
    var failure: String?
    var finished = false
    var depth = 1

    func runtime(_ runtime: any ExtensionCommandRuntime, session: String, didRender tree: RenderTree) {
        trees.append(tree)
    }
    func runtime(_ runtime: any ExtensionCommandRuntime, session: String, didFail message: String) {
        failure = message
    }
    func runtime(_ runtime: any ExtensionCommandRuntime, session: String, navigationDepth: Int) {
        depth = navigationDepth
    }
    func runtime(_ runtime: any ExtensionCommandRuntime, session: String, didFinish: Void) { finished = true }
    func runtime(_ runtime: any ExtensionCommandRuntime, log level: String, message: String) {}

    var root: RenderNode? { trees.last?.activeRoot }

    /// The first node of `type` whose title is `title`, anywhere in the newest render.
    func find(_ type: String, title: String? = nil) -> RenderNode? {
        func search(_ node: RenderNode) -> RenderNode? {
            if node.type == type, title == nil || node.string("title") == title { return node }
            for child in node.children { if let hit = search(child) { return hit } }
            for value in node.props.values {
                for nested in value.nodesValue { if let hit = search(nested) { return hit } }
            }
            return nil
        }
        return trees.last?.active.flatMap(search)
    }
}

/// One launched command.
@MainActor
struct Run {
    let runtime: WasmPluginRuntime
    let host: TestHost
    let recorder: Recorder

    func fire(_ node: RenderNode?, _ prop: String = "onAction", _ arguments: [Any] = []) async {
        guard let handler = node?.handler(prop) else { return }
        await runtime.dispatch(session: "s", handler: handler, payload: ExtensionJSON.string(from: arguments))
    }
}

@main
@MainActor
struct WasmPluginTests {
    static var failures = 0
    static var found: [String: PluginCatalog.Found] = [:]

    static func check(
        _ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = ""
    ) {
        if condition() {
            print("PASS  \(name)")
        } else {
            failures += 1
            let detail = detail()
            print("FAIL  \(name)" + (detail.isEmpty ? "" : "\n      \(detail)"))
        }
    }

    static func until(_ seconds: Double = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    static func launch(
        _ plugin: String, _ command: String, host: TestHost = TestHost(), arguments: [String: String] = [:],
        budget: Duration = .seconds(5)
    ) async -> (Run, Error?) {
        let recorder = Recorder()
        guard let module = found[plugin]?.module, let hosted = module.manifest.extensionManifest(),
            let declared = hosted.commands.first(where: { $0.name == command })
        else {
            fatalError("no \(plugin) \(command)")
        }
        let runtime = WasmPluginRuntime(
            module: module, hostAPI: host, appScheme: "tinycast", priority: .userInitiated, callBudget: budget
        )
        runtime.setDelegate(recorder)
        let owner = InstalledExtension(
            manifest: hosted, directory: found[plugin]!.plugin.directory, engine: .plugin)
        let context = ExtensionLaunchContext(
            extensionName: hosted.name, extensionTitle: hosted.title, commandName: command,
            commandMode: declared.mode, assetsPath: "/tmp", supportPath: "/tmp",
            preferences: ["greeting": .string("Hi")], caches: [:], arguments: arguments,
            isDarkAppearance: true)
        do {
            try await runtime.launch(session: "s", owner: owner, command: declared, context: context)
            return (Run(runtime: runtime, host: host, recorder: recorder), nil)
        } catch {
            return (Run(runtime: runtime, host: host, recorder: recorder), error)
        }
    }

    /// An action command, run to its end or failure.
    static func action(
        _ command: String, host: TestHost = TestHost(), budget: Duration = .seconds(5),
        arguments: [String: String] = [:]
    ) async -> Run {
        let (run, error) = await launch("kitchen", command, host: host, arguments: arguments, budget: budget)
        if let error { run.recorder.failure = error.localizedDescription }
        await until { run.recorder.finished || run.recorder.failure != nil }
        try? await Task.sleep(for: .milliseconds(20))
        return run
    }

    static func main() async {
        guard let folder = CommandLine.arguments.dropFirst().first else {
            print("usage: WasmPluginTests <plugins folder>")
            exit(2)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let cache = FileManager.default.temporaryDirectory.appending(
            path: "tinycast-wasm-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let started = Date()
        let scanned = PluginCatalog.scan(URL(filePath: folder), cache: cache)
        let cold = Date().timeIntervalSince(started)
        for entry in scanned { found[entry.plugin.id] = entry }
        catalogChecks(cold: cold, folder: folder, cache: cache)
        await counterChecks()
        await formChecks()
        await actionChecks()
        await failureChecks()
        await oauthChecks()
        await menuBarChecks()
        await exampleChecks()
        if failures > 0 {
            print("\(failures) plugin checks failed.")
            exit(1)
        }
        print("All plugin checks passed.")
    }

    // MARK: - The catalog

    static func catalogChecks(cold: Double, folder: String, cache: URL) {
        let kitchen = found["kitchen"]
        check(
            "the kitchen describes itself", (try? kitchen?.plugin.manifest.get())?.title == "Kitchen",
            String(describing: kitchen?.plugin.manifest))
        let manifest = try? kitchen?.plugin.manifest.get()
        check(
            "with its commands and their modes",
            manifest?.commands.map(\.mode) == [
                .view, .view, .action, .action, .action, .action, .action, .action,
                .action, .action, .action, .menuBar
            ],
            String(describing: manifest?.commands.map(\.name)))
        check(
            "its permissions, schemes and preferences",
            manifest?.permissions == [.clipboard] && manifest?.urlSchemes == ["kitchen-app"]
                && manifest?.preferences.map(\.name) == ["greeting"])
        check(
            "an argument and an interval",
            manifest?.commands.first { $0.name == "hello" }?.arguments.map(\.name) == ["subject"]
                && manifest?.commands.first { $0.name == "status" }?.interval == "1m")
        print("      described every plugin cold in \(String(format: "%.2f", cold)) s")
        let warmStart = Date()
        let again = PluginCatalog.scan(URL(filePath: folder), cache: cache)
        print("      and from the cache in \(String(format: "%.3f", Date().timeIntervalSince(warmStart))) s")
        let sorted = Array(found.values).sorted { $0.plugin.id < $1.plugin.id }
        check("a second scan reads the cache to the same result", again == sorted)
    }

    // MARK: - A view: state, actions, navigation, storage

    static func counterChecks() async {
        let host = TestHost()
        host.storage = ["visits": 2]
        let started = Date()
        let (run, error) = await launch("kitchen", "counter", host: host)
        check("a view launches", error == nil, String(describing: error))
        await until { run.recorder.find("List.Item", title: "Count 0")?.string("subtitle") == "Visits 3" }
        print(
            "      first render after \(String(format: "%.0f", Date().timeIntervalSince(started) * 1000)) ms")
        check(
            "it renders a List", run.recorder.root?.type == "List",
            String(describing: run.recorder.root?.type))
        check(
            "its task ran and wrote @AppStorage through the host",
            run.recorder.find("List.Item", title: "Count 0")?.string("subtitle") == "Visits 3"
                && host.saw("storage.set visits 3"), host.log.joined(separator: " | "))
        check("a section takes the list's name", run.recorder.find("List.Section") != nil)
        let first = run.recorder.find("List.Item", title: "Count 0")
        await run.fire(run.recorder.find("Action", title: "Add"))
        await until { run.recorder.find("List.Item", title: "Count 1") != nil }
        let second = run.recorder.find("List.Item", title: "Count 1")
        check("an action changes @State and renders again", second != nil)
        check("a row keeps its id across renders", first?.id == second?.id && first != nil)
        await run.fire(run.recorder.find("Action", title: "Copy"))
        await until { host.saw("clipboard.copy") }
        check(
            "a copy button copies through the host", host.saw("clipboard.copy"),
            host.log.joined(separator: " | "))
        await run.fire(run.recorder.find("Action", title: "Details"))
        await until { run.recorder.depth == 2 }
        check(
            "a navigation link pushes a screen",
            run.recorder.depth == 2 && run.recorder.root?.type == "Detail",
            String(describing: run.recorder.root?.type))
        check("the pushed screen has the value it was given", run.recorder.root?.string("markdown") == "# 1")
        let popped = await run.runtime.popNavigation(session: "s")
        await until { run.recorder.depth == 1 }
        check("popping goes back to the first screen", popped && run.recorder.root?.type == "List")
        let again = await run.runtime.popNavigation(session: "s")
        check("the first screen doesn't pop", !again)
        await run.runtime.stop(session: "s")
        run.runtime.shutdown()
    }

    static func formChecks() async {
        let (run, error) = await launch("kitchen", "note")
        check("a form launches", error == nil, String(describing: error))
        await until { run.recorder.find("Form.TextField") != nil }
        let field = run.recorder.find("Form.TextField")
        check("its field renders", field != nil, String(describing: run.recorder.root))
        await run.fire(field, "onTinycastChange", ["Groceries"])
        await until { run.recorder.find("Form.TextField")?.string("value") == "Groceries" }
        check(
            "typing reaches the binding", run.recorder.find("Form.TextField")?.string("value") == "Groceries")
        await run.runtime.dispatch(
            session: "s", handler: run.recorder.find("Action", title: "Save")?.handler("onAction") ?? "",
            payload: "[{}]", completesSession: true)
        await until { run.recorder.finished }
        check(
            "submitting stores the field and runs the action, then finishes",
            run.host.saw("form.store note") && run.host.saw("feedback.showHUD saved Groceries")
                && run.recorder.finished,
            run.host.log.joined(separator: " | "))
        run.runtime.shutdown()
    }

    // MARK: - Actions

    static func actionChecks() async {
        let hello = await action("hello", arguments: ["subject": "World"])
        check(
            "an action reads its preference and argument", hello.host.saw("feedback.showHUD Hi World"),
            hello.host.log.joined(separator: " | ") + (hello.recorder.failure ?? ""))
        check("and finishes", hello.recorder.finished)

        let store = await action("store")
        check(
            "LocalStorage and Cache read back what they wrote", store.host.saw("feedback.showHUD 42 cached"),
            store.host.log.joined(separator: " | "))
        check(
            "and write through to the host",
            store.host.saw("storage.set count 41") && store.host.saw("cache.set default last cached"))

        // A toast's button works while its command runs; the fixture's stays open a moment for it.
        let (toast, _) = await launch("kitchen", "toast")
        await until { toast.host.saw("feedback.showToast") }
        check(
            "a toast shows with its action", toast.host.saw("feedback.showToast"),
            toast.host.log.joined(separator: " | "))
        let shown = toast.host.log.first { $0.hasPrefix("feedback.showToast") } ?? ""
        let token =
            shown.range(of: "plugin-toast-[0-9]+", options: .regularExpression).map { String(shown[$0]) }
            ?? ""
        await toast.runtime.runToastAction(token: token)
        await until { toast.host.saw("feedback.showHUD undone") }
        check("its button runs the closure", toast.host.saw("feedback.showHUD undone"), "token \(token)")
        await until { toast.recorder.finished }
        check("and the command still finishes", toast.recorder.finished)

        let sleepy = await action("sleepy")
        check(
            "Task.sleep and two concurrent host calls both resolve",
            sleepy.host.saw("feedback.showHUD woke clip clip"),
            sleepy.host.log.joined(separator: " | ") + (sleepy.recorder.failure ?? ""))

        let open = await action("open-scheme")
        await until { open.recorder.failure != nil }
        check("a declared app scheme opens", open.host.saw("system.open kitchen-app://hello"))
        check(
            "an undeclared one is refused before the host sees it",
            !open.host.saw("system.open other-app") && open.recorder.failure?.contains("other-app") == true,
            open.recorder.failure ?? "-")
    }

    // MARK: - What a plugin can't do

    static func failureChecks() async {
        let denied = await action("fetch-denied")
        check(
            "fetch without the network permission fails with why",
            denied.recorder.failure?.contains("network") == true && !denied.host.saw("fetch"),
            denied.recorder.failure ?? "-")

        let started = Date()
        let spin = await action("spin", budget: .milliseconds(300))
        let took = Date().timeIntervalSince(started)
        check(
            "a hung command is stopped at its deadline",
            spin.recorder.failure?.contains("stopped it") == true && took < 3,
            (spin.recorder.failure ?? "-") + " after \(took) s")

        let crash = await action("crash")
        check(
            "a crash fails the command with Swift's own message",
            crash.recorder.failure?.contains("kitchen crashed with 0 values") == true,
            crash.recorder.failure ?? "-")
    }

    static func oauthChecks() async {
        let signIn = await action("sign-in")
        let authorize = signIn.host.log.first { $0.hasPrefix("oauth.authorize") } ?? ""
        let query =
            URLComponents(string: authorize.components(separatedBy: " ")[safe: 1] ?? "")?.queryItems ?? []
        func item(_ name: String) -> String? { query.first { $0.name == name }?.value }
        check(
            "a sign-in runs to its end", signIn.recorder.finished && signIn.recorder.failure == nil,
            signIn.recorder.failure ?? signIn.host.log.joined(separator: " | "))
        check(
            "with PKCE's S256 challenge, the plugin's redirect and extra parameters",
            item("code_challenge_method") == "S256" && item("code_challenge")?.count == 43
                && item("redirect_uri") == "tinycast://oauth?plugin=kitchen" && item("prompt") == "consent",
            authorize)
        check(
            "tokens are kept and read back fresh",
            signIn.host.saw("feedback.showHUD token-for-granted fresh 43"),
            signIn.host.log.joined(separator: " | "))

        let forgedHost = TestHost()
        forgedHost.redirectQuery = "code=granted&state=forged"
        let forged = await action("sign-in", host: forgedHost)
        check(
            "a redirect with another state is refused",
            forged.recorder.failure?.contains("mismatched state") == true,
            forged.recorder.failure ?? "-")
        let refusedHost = TestHost()
        refusedHost.redirectQuery = "error=access_denied&error_description=The+user+said+no"
        let refused = await action("sign-in", host: refusedHost)
        check(
            "the provider's error reaches the plugin",
            refused.recorder.failure?.contains("The user said no") == true,
            refused.recorder.failure ?? "-")
    }

    static func menuBarChecks() async {
        let (run, error) = await launch("kitchen", "status")
        check("a menu bar command launches", error == nil, String(describing: error))
        await until { run.recorder.root?.string("title") == "Ready" }
        check(
            "it renders its status item, and updates it from its task",
            run.recorder.root?.type == "MenuBarExtra" && run.recorder.root?.string("title") == "Ready",
            String(describing: run.recorder.root))
        await run.fire(run.recorder.find("MenuBarExtra.Item", title: "Ping"))
        await until { run.host.saw("feedback.showHUD pong") }
        check("its items run their actions", run.host.saw("feedback.showHUD pong"))
        run.runtime.shutdown()
    }

    // MARK: - The examples

    static func exampleChecks() async {
        guard let news = found["hacker-news"] else { return check("the Hacker News example is built", false) }
        check(
            "Hacker News describes itself",
            (try? news.plugin.manifest.get())?.commands.map(\.name) == ["stories", "top-story"],
            String(describing: news.plugin.manifest))
        let host = TestHost()
        host.answers["fetch.request"] = ExtensionJSON.string(from: [
            "status": 200, "statusText": "OK", "headers": [:], "url": "https://hn.algolia.com",
            "bodyBase64": Data(
                (#"{"hits":[{"objectID":"1","title":"Wasm in Tinycast","url":"https://example.com/a","points":42,"#
                    + #""num_comments":7,"created_at_i":0}]}"#).utf8
            ).base64EncodedString()
        ])
        let (run, error) = await launch("hacker-news", "stories", host: host)
        check("its stories launch", error == nil, String(describing: error))
        await until {
            run.recorder.find("List.Item", title: "Wasm in Tinycast") != nil || run.recorder.failure != nil
        }
        check(
            "and list what the feed returned",
            run.recorder.find("List.Item", title: "Wasm in Tinycast")?.string("subtitle") == "example.com",
            (run.recorder.failure ?? "") + host.log.joined(separator: " | "))
        check("fetching through the host", host.saw("fetch.request"))
        run.runtime.shutdown()

        guard let cleanShot = found["cleanshot-x"], let manifest = try? cleanShot.plugin.manifest.get() else {
            return check("the CleanShot X example is built", false)
        }
        check(
            "CleanShot X declares its view and a command per tool",
            manifest.commands.count == 20 && manifest.commands.first?.mode == .view
                && manifest.commands.first { $0.name == "capture-text" }?.keywords == [
                    "ocr", "text recognition"
                ],
            "\(manifest.commands.count) commands")
        let (tools, toolsError) = await launch("cleanshot-x", "cleanshot")
        await until { tools.recorder.root != nil }
        check(
            "its list has a section per kind of tool",
            toolsError == nil
                && tools.recorder.root?.children.filter { $0.type == "List.Section" }.count == 5,
            String(describing: tools.recorder.root?.children.map(\.type)))
        tools.runtime.shutdown()
        let (capture, _) = await launch("cleanshot-x", "capture-area")
        await until { capture.recorder.finished || capture.recorder.failure != nil }
        check(
            "a tool's command opens its CleanShot link",
            capture.host.saw("system.open cleanshot://capture-area"),
            (capture.recorder.failure ?? "") + capture.host.log.joined(separator: " | "))
        capture.runtime.shutdown()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
