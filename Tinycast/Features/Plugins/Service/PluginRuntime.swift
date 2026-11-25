import Foundation

/// One plugin command's session as the host drives it, in the app or in the plugin helper:
/// launched, sent the user's events, stopped. What it draws comes back through the delegate.
@MainActor
protocol PluginRuntime: AnyObject {
    func setDelegate(_ delegate: any PluginRuntimeDelegate)
    func launch(session: String, launch: PluginLaunch) async throws
    /// `completesSession` ends the session once the event and the host calls it made are done:
    /// a menu-bar command's item, which runs and leaves.
    func send(_ event: PluginEvent, session: String, completesSession: Bool) async
    func runToastAction(token: String) async
    func stop(session: String) async
    /// Returns once the host calls made so far are answered, so a copy or a HUD an action ends
    /// with reaches the app before its session stops.
    func drainHostCalls() async
    func shutdown()
}

@MainActor
protocol PluginRuntimeDelegate: AnyObject {
    func runtime(_ runtime: any PluginRuntime, session: String, didRender frame: PluginFrame)
    /// The error replaces the screen.
    func runtime(_ runtime: any PluginRuntime, session: String, didFail message: String)
    /// An action command returned, or a completing event was handled.
    func runtime(_ runtime: any PluginRuntime, session: String, didFinish: Void)
}
