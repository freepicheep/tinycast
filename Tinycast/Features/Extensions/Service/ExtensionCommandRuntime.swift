import Foundation

/// One command's runtime, as the palette, background and menu-bar lanes drive it. A runtime
/// renders `RenderTree`s through its delegate, takes handler ids back, and reaches the app only
/// through the `ExtensionHostAPI` it was made with.
@MainActor
protocol ExtensionCommandRuntime: AnyObject {
    func setDelegate(_ delegate: ExtensionRuntimeDelegate)
    /// Idempotent, so any command can lazily ensure the engine is up.
    func boot(config: ExtensionBootConfig) async throws
    /// Reads the command's code and mounts it; throws `ExtensionLaunchError` when there is none.
    func launch(
        session: String, owner: InstalledExtension, command: ExtensionCommand,
        context: ExtensionLaunchContext
    ) async throws
    /// `payload` is a JSON array of the handler's arguments.
    func dispatch(session: String, handler: String, payload: String, completesSession: Bool) async
    /// Escape or the back chevron inside a pushed screen; true when one was popped.
    func popNavigation(session: String) async -> Bool
    func runToastAction(token: String) async
    func stop(session: String) async
    /// Waits until host calls the command started have answered.
    func drainHostCalls() async
    /// Discards the engine's state outright, so nothing reaches the next run.
    func shutdown()
}

extension ExtensionCommandRuntime {
    func dispatch(session: String, handler: String, payload: String) async {
        await dispatch(session: session, handler: handler, payload: payload, completesSession: false)
    }
}

/// Makes the runtime for a plugin's command; the Plugins feature supplies it while it is on.
typealias ExtensionPluginRuntimeFactory =
    @MainActor (InstalledExtension, ExtensionHostAPI, DispatchQoS) -> any ExtensionCommandRuntime
