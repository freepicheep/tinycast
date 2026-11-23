import Tinycast

Plugin.command("cities") { Cities() }
Plugin.action("hello") {
    try await Task.sleep(for: .milliseconds(5))
    showHUD("Hello from \(Plugin.commandName)")
}
