import Foundation
import Scrift

/// What a plugin's session asks of the app, which checks and performs it: the clipboard, opening
/// things, feedback, the palette, other commands, applications, sign-in and the selection.
enum PluginHostCall: Codable, Sendable, Equatable {
    case copy(String, concealed: Bool)
    case paste(String)
    case clearClipboard
    /// A target `PluginOpenTarget` allows, optionally with an application's name, bundle id or path.
    case open(String, application: String?)
    case showInFinder(String)
    case openWith(String)
    case trash([String])
    case showHUD(String)
    /// Answered with the toast's id, for `updateToast` and `hideToast`.
    case showToast(PluginToast)
    case updateToast(Int, PluginToast)
    case hideToast(Int)
    /// Answered with whether the user confirmed.
    case confirm(PluginAlert)
    case closeMainWindow(clearRootSearch: Bool)
    case popToRoot
    case clearSearchBar
    case openPreferences
    /// Another of the plugin's own commands.
    case launchCommand(String, background: Bool, arguments: [String: String], context: [String: PluginValue])
    /// Nil puts back the manifest's subtitle.
    case updateCommandMetadata(subtitle: String?)
    case applications(path: String?)
    case defaultApplication(path: String)
    case frontmostApplication
    /// Opens a sign-in and answers with the redirect to `scheme` that ends it.
    case authorize(url: String, scheme: String)
    /// Nil removes the provider's tokens.
    case setTokens(provider: String, PluginOAuthTokens?)
    case tokens(provider: String)
    case selectedText
    case selectedFinderItems
}

/// The app's answer to a `PluginHostCall`.
enum PluginHostAnswer: Codable, Sendable, Equatable {
    case none
    case bool(Bool)
    case int(Int)
    case text(String)
    case texts([String])
    case application(PluginApplication?)
    case applications([PluginApplication])
    case tokens(PluginOAuthTokens?)
}

/// A toast as a plugin shows it; `actionToken` names the closure its button runs.
struct PluginToast: Codable, Sendable, Equatable {
    enum Style: String, Codable, Sendable {
        case success
        case failure
        /// A spinner, until the toast changes or hides.
        case animated
    }

    var style: Style
    var title: String
    var message: String?
    var actionTitle: String?
    var actionToken: String?
}

struct PluginAlert: Codable, Sendable, Equatable {
    var title: String
    var message: String?
    var primaryTitle: String?
    var isDestructive: Bool
}

/// The app's end of a session's host calls: in the app, or across the plugin helper's pipe.
@MainActor
protocol PluginHostAPI: AnyObject {
    func perform(_ call: PluginHostCall) async throws -> PluginHostAnswer
    /// The session is over: whatever the app kept for it (toasts, a pending sign-in) goes.
    func sessionEnded()
}

/// A host call the app can't answer, as its message.
struct PluginHostError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static let noSession = PluginHostError(message: "The plugin's command isn't running.")
}
