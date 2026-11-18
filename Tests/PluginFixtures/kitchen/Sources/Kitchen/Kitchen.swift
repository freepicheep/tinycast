import FoundationEssentials
import TinycastKit

@main
struct Kitchen: Plugin {
    let manifest = Manifest(
        name: "kitchen", title: "Kitchen", icon: "fork.knife", permissions: [.clipboard],
        urlSchemes: ["kitchen-app"],
        preferences: [.textfield("greeting", title: "Greeting", default: "Hello")])

    var commands: [Command] {
        Command.view("counter", title: "Counter") { Counter() }
        Command.view("note", title: "Note") { Note() }
        Command.action("hello", title: "Hello", arguments: [.text("subject", placeholder: "Who")]) {
            let greeting = getPreferenceValues()["greeting"]?.text ?? "?"
            showHUD("\(greeting) \(Launch.arguments["subject"] ?? "")")
        }
        Command.action("store", title: "Store") {
            LocalStorage.setItem("count", 41)
            Cache().set("last", "cached")
            let count: Int = LocalStorage.item("count") ?? 0
            showHUD("\(count + 1) \(Cache().get("last") ?? "-")")
        }
        Command.action("toast", title: "Toast") {
            await showToast(.success, title: "Saved", actionTitle: "Undo") { showHUD("undone") }
            try await Task.sleep(for: .milliseconds(300))
        }
        Command.action("sleepy", title: "Sleepy") {
            try await Task.sleep(for: .milliseconds(50))
            async let first = Clipboard.readText()
            async let second = Clipboard.readText()
            showHUD("woke \(try await first ?? "") \(try await second ?? "")")
        }
        Command.action("fetch-denied", title: "Fetch") {
            _ = try await fetch("https://example.com")
        }
        Command.action("open-scheme", title: "Open") {
            open("kitchen-app://hello")
            open("other-app://nope")
        }
        Command.action("spin", title: "Spin") {
            var seen = Set<Int>()
            var value = 1
            while true {
                value = value &* 1_103_515_245 &+ 12_345
                if seen.count > 3 { seen.removeAll() }
                seen.insert(value)
                if value == 0 { break }
            }
            showHUD("never \(value)")
        }
        Command.action("crash", title: "Crash") {
            let values: [Int] = []
            fatalError("kitchen crashed with \(values.count) values")
        }
        Command.action("sign-in", title: "Sign In") {
            let client = OAuth.PKCEClient(providerName: "Example")
            let request = try client.authorizationRequest(
                endpoint: "https://auth.example.com/authorize", clientID: "kitchen-client", scope: "read",
                extraParameters: ["prompt": "consent"])
            let code = try await client.authorize(request)
            try await client.setTokens(
                accessToken: "token-for-\(code)", refreshToken: "refresh", expiresIn: 3600)
            guard let tokens = try await client.getTokens() else { return }
            showHUD(
                "\(tokens.accessToken) \(tokens.isExpired ? "expired" : "fresh") \(request.codeChallenge.count)"
            )
        }
        Command.menuBar("status", title: "Status", interval: "1m") { Status() }
    }
}

struct Counter: View {
    @State private var count = 0
    @AppStorage("visits") private var visits = 0

    var body: some View {
        List {
            Item("Count \(count)", subtitle: "Visits \(visits)")
                .id("count")
                .actions {
                    Button("Add") { count += 1 }
                    NavigationLink("Details") { Details(count: count) }
                    CopyButton("Copy", text: "\(count)")
                }
            Section("More") {
                Item("Second").id("second")
            }
        }
        .task { visits += 1 }
    }
}

struct Details: View {
    let count: Int

    var body: some View {
        Detail(markdown: "# \(count)")
    }
}

struct Note: View {
    @State private var title = ""

    var body: some View {
        Form {
            TextField("Title", text: $title).storeValue()
        }
        .actions {
            SubmitButton("Save") { showHUD("saved \(title)") }
        }
    }
}

struct Status: View {
    @State private var label = "…"

    var body: some View {
        MenuBarExtra(label, systemImage: "circle") {
            MenuItem("Ping") { showHUD("pong") }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(20))
            label = "Ready"
        }
    }
}
