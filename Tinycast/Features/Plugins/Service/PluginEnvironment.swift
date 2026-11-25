import CryptoKit
import Foundation
import Security
import Scrift

/// The one host object a plugin's session holds. The kit keeps it in a global, so every call is
/// scoped to the session that made it, and a plugin reaches only its own storage. Everything but
/// storage is a `PluginHostCall` the app checks and performs.
@ScriftExport
@MainActor
final class PluginEnvironment {
    private var name = ""
    private var command = ""
    private var urlSchemes: Set<String> = []
    /// Tinycast's own scheme (`tinycast`, or `tinycast-dev` in Debug), where an OAuth sign-in returns.
    private var appScheme = "tinycast"
    private var storage: (any PluginStorage)?
    private var hostAPI: (any PluginHostAPI)?
    private var onInvalidate: () -> Void = {}
    private var toastActions: [String: () throws -> Void] = [:]
    private var nextToastAction = 1
    private var onError: (any Error) -> Void = { _ in }
    /// Fire-and-forget calls not yet answered, and who waits for none to be left.
    private var callsInFlight = 0
    private var callWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    var pluginName: String { name }
    var commandName: String { command }

    /// A `@State` changed: the session renders again once the current script call returns.
    func invalidate() { onInvalidate() }

    // MARK: - Storage, which a getter reads synchronously

    /// An `@AppStorage` value's JSON text.
    func storedValue(forKey key: String) -> String? {
        storage?.value(plugin: name, key: key)
    }

    /// Nil removes the key.
    func setStoredValue(_ value: String?, forKey key: String) {
        storage?.setValue(value, plugin: name, key: key)
    }

    func storedKeys() -> [String] {
        (storage?.values(plugin: name) ?? [:]).keys.sorted()
    }

    func clearStoredValues() {
        storage?.clearValues(plugin: name)
    }

    // MARK: - Clipboard: writing needs no permission, since the user asked for it

    func copy(_ text: String, concealed: Bool) { call(.copy(text, concealed: concealed)) }
    func paste(_ text: String) { call(.paste(text)) }
    func clearClipboard() { call(.clearClipboard) }

    // MARK: - Opening things

    /// Web, mail and file targets, and the app link schemes the manifest names; anything else is
    /// refused here, before it reaches the app, which checks again.
    func open(_ target: String, application: String?) {
        guard PluginOpenTarget.resolve(target, schemes: urlSchemes) != nil else {
            let scheme = URL(string: target)?.scheme ?? target
            showHUD(String(localized: "This plugin can't open \(scheme) links: Manifest.swift doesn't list them"))
            return
        }
        call(.open(target, application: application))
    }

    func showInFinder(_ path: String) { call(.showInFinder(path)) }
    func openWith(_ path: String) { call(.openWith(path)) }

    /// Only a `TrashButton` reaches this: the user chose the action that names the paths.
    func trash(_ paths: [String]) { call(.trash(paths)) }

    // MARK: - Feedback

    func showHUD(_ text: String) { call(.showHUD(text)) }

    /// Keeps a toast's action under a token the app sends back when its button is pressed.
    /// Separate from `showToast`, which awaits and so can't take a closure across the boundary.
    func toastToken(_ action: @escaping () throws -> Void) -> String {
        let token = "plugin-toast-\(nextToastAction)"
        nextToastAction += 1
        toastActions[token] = action
        return token
    }

    /// The toast's id, for `updateToast` and `hideToast`. `style` is `success`, `failure` or `animated`.
    func showToast(
        style: String, title: String, message: String?, actionTitle: String?, actionToken: String?
    ) async throws -> Int {
        let toast = Self.toast(style, title, message, actionTitle, actionToken)
        guard case .int(let id) = try await perform(.showToast(toast)) else { return 0 }
        return id
    }

    func updateToast(
        _ id: Int, style: String, title: String, message: String?, actionTitle: String?, actionToken: String?
    ) {
        call(.updateToast(id, Self.toast(style, title, message, actionTitle, actionToken)))
    }

    func hideToast(_ id: Int) { call(.hideToast(id)) }

    func confirm(
        title: String, message: String?, primaryTitle: String?, isDestructive: Bool
    ) async throws -> Bool {
        let alert = PluginAlert(
            title: title, message: message, primaryTitle: primaryTitle, isDestructive: isDestructive)
        guard case .bool(let confirmed) = try await perform(.confirm(alert)) else { return false }
        return confirmed
    }

    // MARK: - The palette and the launcher

    func closeMainWindow(clearRootSearch: Bool) { call(.closeMainWindow(clearRootSearch: clearRootSearch)) }
    func popToRoot() { call(.popToRoot) }
    func clearSearchBar() { call(.clearSearchBar) }
    func openPreferences() { call(.openPreferences) }

    /// Another of this plugin's commands; a plugin can't launch another's.
    func launchCommand(
        _ commandName: String, background: Bool, arguments: [String: String],
        context: [String: PluginValue]
    ) async throws {
        _ = try await perform(
            .launchCommand(commandName, background: background, arguments: arguments, context: context))
    }

    /// Nil puts back the manifest's subtitle.
    func updateCommandMetadata(subtitle: String?) { call(.updateCommandMetadata(subtitle: subtitle)) }

    // MARK: - Applications

    func applications(forPath path: String?) async throws -> [PluginApplication] {
        guard case .applications(let found) = try await perform(.applications(path: path)) else { return [] }
        return found
    }

    func defaultApplication(for path: String) async throws -> PluginApplication? {
        guard case .application(let found) = try await perform(.defaultApplication(path: path)) else { return nil }
        return found
    }

    func frontmostApplication() async throws -> PluginApplication? {
        guard case .application(let found) = try await perform(.frontmostApplication) else { return nil }
        return found
    }

    // MARK: - OAuth: PKCE runs here, natively; the host runs the browser sign-in and keeps the tokens

    /// The URL that starts a sign-in, with a fresh verifier, its S256 challenge and a state nonce.
    /// `redirectURI` nil means Tinycast's own `<scheme>://oauth?plugin=<name>`.
    func oauthRequest(
        endpoint: String, clientID: String, scope: String, extraParameters: [String: String],
        redirectURI: String?
    ) throws -> PluginOAuthRequest {
        guard var components = URLComponents(string: endpoint), components.scheme == "https" else {
            throw PluginOAuthError.invalidEndpoint(endpoint)
        }
        let verifier = Self.randomURLSafe(32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(16)
        let redirect = redirectURI ?? "\(appScheme)://oauth?plugin=\(name)"
        var items = [
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect), URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        for (key, value) in extraParameters.sorted(by: { $0.key < $1.key }) {
            items.removeAll { $0.name == key }
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = (components.queryItems ?? []) + items
        guard let url = components.url else { throw PluginOAuthError.invalidEndpoint(endpoint) }
        return PluginOAuthRequest(
            url: url.absoluteString, codeVerifier: verifier, codeChallenge: challenge, state: state,
            redirectURI: redirect)
    }

    /// Opens the sign-in and waits for the redirect to `redirectURI`'s scheme; the authorization
    /// code, once the redirect's state matches the request's.
    func oauthAuthorize(_ request: PluginOAuthRequest, providerName: String) async throws -> String {
        guard let scheme = URL(string: request.redirectURI)?.scheme else {
            throw PluginOAuthError.invalidRedirect(request.redirectURI)
        }
        guard case .text(let redirect) = try await perform(.authorize(url: request.url, scheme: scheme)) else {
            throw PluginOAuthError.noCode(providerName)
        }
        // A redirect's query is form-encoded (RFC 6749 §4.1.2): `+` is a space, as `URLSearchParams` reads it.
        var components = URLComponents(string: redirect)
        let query = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        components?.percentEncodedQuery = query
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw PluginOAuthError.provider(value("error_description") ?? error) }
        let states = items.filter { $0.name == "state" }.map(\.value)
        guard states == [request.state] else { throw PluginOAuthError.mismatchedState(providerName) }
        guard let code = value("code"), !code.isEmpty else { throw PluginOAuthError.noCode(providerName) }
        return code
    }

    /// Kept by the app under the plugin's name and the provider's.
    func setOAuthTokens(
        provider: String, accessToken: String, refreshToken: String?, idToken: String?, expiresIn: Double?,
        scope: String?
    ) async throws {
        let tokens = PluginOAuthTokens(
            accessToken: accessToken, refreshToken: refreshToken, idToken: idToken, expiresIn: expiresIn,
            scope: scope, updatedAt: Date().timeIntervalSince1970)
        _ = try await perform(.setTokens(provider: provider, tokens))
    }

    func oauthTokens(provider: String) async throws -> PluginOAuthTokens? {
        guard case .tokens(let tokens) = try await perform(.tokens(provider: provider)) else { return nil }
        return tokens
    }

    func removeOAuthTokens(provider: String) async throws {
        _ = try await perform(.setTokens(provider: provider, nil))
    }

    private static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "the system's random generator failed")
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Plumbing

    private static func toast(
        _ style: String, _ title: String, _ message: String?, _ actionTitle: String?, _ token: String?
    ) -> PluginToast {
        PluginToast(
            style: PluginToast.Style(rawValue: style) ?? .success, title: title, message: message,
            actionTitle: token == nil ? nil : (actionTitle ?? String(localized: "Open")), actionToken: token)
    }

    /// Fire and forget: a failure is the plugin's, reported on its screen. The runtime waits for
    /// these (`callsAnswered`) before it says a command finished, so a copy or a HUD an action
    /// ends with reaches the app before its session stops.
    private func call(_ call: PluginHostCall) {
        guard let hostAPI else { return }
        let report = onError
        callsInFlight += 1
        Task { @MainActor in
            do {
                _ = try await hostAPI.perform(call)
            } catch {
                report(error)
            }
            self.callAnswered()
        }
    }

    private func callAnswered() {
        callsInFlight -= 1
        guard callsInFlight == 0 else { return }
        let waiters = callWaiters
        callWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Returns once every fire-and-forget call made so far has been answered.
    func callsAnswered() async {
        guard callsInFlight > 0 else { return }
        await withCheckedContinuation { callWaiters.append($0) }
    }

    private func perform(_ call: PluginHostCall) async throws -> PluginHostAnswer {
        guard let hostAPI else { throw PluginHostError.noSession }
        return try await hostAPI.perform(call)
    }
}

/// A sign-in about to start: what `OAuth.PKCEClient.authorizationRequest` returns.
@ScriftExport
struct PluginOAuthRequest {
    var url: String
    var codeVerifier: String
    var codeChallenge: String
    var state: String
    var redirectURI: String
}

/// A provider's stored tokens; `updatedAt` in seconds since 1970.
@ScriftExport
struct PluginOAuthTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresIn: Double?
    var scope: String?
    var updatedAt: Double
}

/// Described by its message: a plugin sees a host error as its descriptions, not its type.
enum PluginOAuthError: LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
    case invalidEndpoint(String)
    case invalidRedirect(String)
    case provider(String)
    case mismatchedState(String)
    case noCode(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let endpoint): "An OAuth endpoint must be an https URL, not \(endpoint)."
        case .invalidRedirect(let uri): "\(uri) isn't a redirect URI an app can receive."
        case .provider(let message): message
        case .mismatchedState(let provider): "\(provider) sign-in returned a mismatched state."
        case .noCode(let provider): "\(provider) sign-in returned no authorization code."
        }
    }

    var description: String { errorDescription ?? "" }
    var debugDescription: String { description }
}

/// An application as `getApplications` describes it.
@ScriftExport
struct PluginApplication: Codable, Sendable, Equatable {
    var name: String
    var path: String
    var bundleID: String?
}

extension PluginEnvironment {
    static func make(
        plugin: PluginManifest, command: String, storage: any PluginStorage, hostAPI: any PluginHostAPI,
        appScheme: String, onInvalidate: @escaping () -> Void, onError: @escaping (any Error) -> Void
    ) -> PluginEnvironment {
        let environment = PluginEnvironment()
        environment.appScheme = appScheme
        environment.name = plugin.name
        environment.command = command
        environment.urlSchemes = plugin.urlSchemes
        environment.storage = storage
        environment.hostAPI = hostAPI
        environment.onInvalidate = onInvalidate
        environment.onError = onError
        return environment
    }

    /// A toast's button: the closure the script gave `showToast`.
    func toastAction(_ token: String) -> (() throws -> Void)? { toastActions[token] }

    /// The session is over: a closure the script kept can no longer reach the app.
    func detach() {
        hostAPI = nil
        storage = nil
        onInvalidate = {}
        onError = { _ in }
        toastActions = [:]
    }
}
