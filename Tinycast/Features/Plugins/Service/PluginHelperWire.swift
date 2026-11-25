import Foundation

// The frames between the app and the plugin helper, the process plugin code runs in. Each is one
// JSON value over `ProcessLink`. The app numbers each runtime it asks for, and each request that
// waits for an answer, and the helper answers with that number; the helper numbers its host calls,
// which the app answers the same way.

/// What the app asks of the plugin helper.
enum PluginHelperRequest: Codable, Sendable {
    /// A command's start, in a runtime of its own that `runtime` names from then on.
    case launch(runtime: Int, reply: Int, launch: PluginHelperLaunch)
    /// What the user did on the session's last frame.
    case event(runtime: Int, reply: Int, session: String, event: PluginEvent, completesSession: Bool)
    case toastAction(runtime: Int, reply: Int, token: String)
    case stop(runtime: Int, reply: Int, session: String)
    case drain(runtime: Int, reply: Int)
    /// The runtime's end: nothing of it is kept.
    case shutdown(runtime: Int)
    /// The app's answer to the helper's host call `call`, or why it failed.
    case hostAnswer(call: Int, answer: PluginHostAnswer?, error: String?)
    /// Every plugin folder in `directory` with its manifest, run against the description.
    case scan(reply: Int, directory: String, description: String?, cache: String?)
    /// Compiles the kit into the cache ahead of the first launch.
    case warm(kitDirectory: String)
    /// Nothing to do: the helper exits once nothing runs, and its memory goes with it.
    case exitWhenIdle
    /// Answered at once from the helper's main thread: the app's watchdog ends a helper that
    /// stops answering, whatever a plugin or a host function is stuck in.
    case ping(reply: Int)
}

/// Everything a launch in the helper needs, since the helper keeps nothing between launches but
/// its compile cache.
struct PluginHelperLaunch: Codable, Sendable {
    var session: String
    /// The manifest as the app listed it, in `PluginManifest`'s JSON.
    var manifest: Data
    var pluginDirectory: String
    var kitDirectory: String
    var launch: PluginLaunch
    var appScheme: String
    var storage: PluginStorageSnapshot
}

/// A plugin folder as the helper's scan found it.
struct PluginHelperScanned: Codable, Sendable {
    var directory: String
    /// `PluginManifest`'s JSON, or nil with `error`.
    var manifest: Data?
    var error: PluginManifestError?
}

/// What the helper tells the app.
enum PluginHelperEvent: Codable, Sendable {
    case reply(Int, PluginHelperReply)
    case rendered(runtime: Int, session: String, frame: PluginFrame)
    case failed(runtime: Int, session: String, message: String)
    case finished(runtime: Int, session: String)
    /// A call to the app's `PluginHostAPI`, which `PluginHelperRequest.hostAnswer` answers.
    case hostCall(runtime: Int, call: Int, PluginHostCall)
    case sessionEnded(runtime: Int)
    case storage(runtime: Int, write: PluginStorageWrite)
    /// After each runtime ends, so the app can recycle a helper that grew: its memory footprint.
    case footprint(bytes: Int, runtimes: Int)
}

enum PluginHelperReply: Codable, Sendable {
    case done
    case launchFailed(String)
    case scanned([PluginHelperScanned])
}
