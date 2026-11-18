import Tinycast

Plugin.command("note") { Note() }
Plugin.command("colors") { Colors() }
Plugin.menuBar("status") { Status() }

struct Settings {
    @Preference("greeting") var greeting: String
    @Preference("loud") var loud: Bool
}

Plugin.action("toast") {
    let settings = Settings()
    let toast = await showToast(
        .animated, title: settings.loud ? settings.greeting.uppercased() : settings.greeting)
    toast.style = .success
    toast.message = Plugin.launchType == .background ? "background" : "user"
    toast.setAction("Undo") { showHUD("Undone") }
}

Plugin.action("hop") {
    try await launchCommand("note", arguments: ["subject": "From hop"], context: ["origin": .string("hop")])
}

Plugin.action("sign-in") {
    let client = OAuth.PKCEClient(providerName: "Example")
    let request = try client.authorizationRequest(
        endpoint: "https://auth.example.com/authorize", clientID: "kitchen-client", scope: "read",
        extraParameters: ["prompt": "consent"])
    let code = try await client.authorize(request)
    try await client.setTokens(accessToken: "token-for-\(code)", refreshToken: "refresh", expiresIn: 3600)
    guard let tokens = try await client.getTokens() else { return }
    showHUD("\(tokens.accessToken) \(tokens.isExpired ? "expired" : "fresh")")
}
