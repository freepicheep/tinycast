import CryptoKit
import Foundation
import Security
import Scrift

/// The one host object a plugin's session holds. The kit keeps it in a global, so every call is
/// scoped to the session that made it, and a plugin reaches only its own storage. Everything but
/// storage goes through the Extensions host's `ExtensionHostAPI`, which is what a Raycast command
/// reaches too: the same toasts, clipboard, windows and launches.
@ScriftExport
@MainActor
final class PluginEnvironment {
    private var name = ""
    private var command = ""
    private var urlSchemes: Set<String> = []
    /// Tinycast's own scheme (`tinycast`, or `tinycast-dev` in Debug), where an OAuth sign-in returns.
    private var appScheme = "tinycast"
    private var storage: ExtensionStorage?
    private var hostAPI: ExtensionHostAPI?
    private var onInvalidate: () -> Void = {}
    private var toastActions: [String: () throws -> Void] = [:]
    private var nextToastAction = 1
    private var onError: (any Error) -> Void = { _ in }

    private init() {}

    var pluginName: String { name }
    var commandName: String { command }

    /// A `@State` changed: the session renders again once the current script call returns.
    func invalidate() { onInvalidate() }

    // MARK: - Storage, which a getter reads synchronously

    func storedValue(forKey key: String) -> PluginValue? {
        guard let value = storage?.localStorageValue(extension: name, key: key) else { return nil }
        return Self.value(value)
    }

    /// Only strings, numbers and booleans are kept, as in Raycast's `LocalStorage`.
    func setStoredValue(_ value: PluginValue?, forKey key: String) {
        guard let value else {
            storage?.removeLocalStorage(extension: name, key: key)
            return
        }
        guard let stored = ExtensionStorage.StoredValue(renderValue: value.renderValue) else { return }
        storage?.setLocalStorage(extension: name, key: key, value: stored)
    }

    func storedValues() -> [String: PluginValue] {
        (storage?.allLocalStorage(extension: name) ?? [:]).mapValues(Self.value)
    }

    func clearStoredValues() {
        storage?.clearLocalStorage(extension: name)
    }

    func cachedValue(namespace: String, key: String) -> String? {
        storage?.caches(extension: name)[namespace]?[key]
    }

    /// A nil value removes the key; a nil key empties the namespace.
    func setCachedValue(_ value: String?, namespace: String, key: String?) {
        storage?.setCache(extension: name, namespace: namespace, key: key, value: value)
    }

    func cachedKeys(namespace: String) -> [String] {
        Array((storage?.caches(extension: name)[namespace] ?? [:]).keys).sorted()
    }

    /// A form's `storeValue` fields, which the next launch of the command starts from.
    func storeFormValues(_ values: [String: String]) {
        guard !values.isEmpty else { return }
        storage?.setFormValues(extension: name, command: command, values: values)
    }

    func storedFormValue(_ field: String) -> String? {
        storage?.formValues(extension: name, command: command)[field]
    }

    // MARK: - Clipboard: writing needs no permission, since the user asked for it

    func copy(_ text: String, concealed: Bool) {
        call("clipboard", "copy", [.object(["text": .string(text)]), .object(["concealed": .bool(concealed)])])
    }

    func paste(_ text: String) {
        call("clipboard", "paste", [.object(["text": .string(text)])])
    }

    func clearClipboard() {
        call("clipboard", "clear", [])
    }

    // MARK: - Opening things

    /// Web, mail and file targets, and the app link schemes the manifest names; anything else is
    /// refused here, before it reaches the host.
    func open(_ target: String, application: String?) {
        guard PluginOpenTarget.resolve(target, schemes: urlSchemes) != nil else {
            let scheme = URL(string: target)?.scheme ?? target
            showHUD(String(localized: "This plugin can't open \(scheme) links: Manifest.swift doesn't list them"))
            return
        }
        var arguments: [RenderValue] = [.string(target)]
        if let application { arguments.append(.string(application)) }
        call("system", "open", arguments)
    }

    func showInFinder(_ path: String) {
        call("system", "showInFinder", [.string(path)])
    }

    func openWith(_ path: String) {
        call("system", "openWith", [.string(path)])
    }

    /// Only a `TrashButton` reaches this: the user chose the action that names the paths.
    func trash(_ paths: [String]) {
        call("system", "trash", [.array(paths.map(RenderValue.string))])
    }

    // MARK: - Feedback

    func showHUD(_ text: String) {
        call("feedback", "showHUD", [.string(text)])
    }

    /// Keeps a toast's action under a token the host sends back when its button is pressed.
    /// Separate from `showToast`, which awaits and so can't take a closure across the boundary.
    func toastToken(_ action: @escaping () throws -> Void) -> String {
        let token = "plugin-toast-\(nextToastAction)"
        nextToastAction += 1
        toastActions[token] = action
        return token
    }

    /// The toast's id, for `updateToast` and `hideToast`.
    func showToast(
        style: String, title: String, message: String?, actionTitle: String?, actionToken: String?
    ) async throws -> Int {
        let payload = toastPayload(style, title, message, actionTitle, actionToken)
        return Int(try await perform("feedback", "showToast", [payload])) ?? 0
    }

    func updateToast(
        _ id: Int, style: String, title: String, message: String?, actionTitle: String?, actionToken: String?
    ) {
        let payload = toastPayload(style, title, message, actionTitle, actionToken)
        call("feedback", "updateToast", [.number(Double(id)), payload])
    }

    func hideToast(_ id: Int) {
        call("feedback", "hideToast", [.number(Double(id))])
    }

    func confirm(
        title: String, message: String?, primaryTitle: String?, isDestructive: Bool
    ) async throws -> Bool {
        var primary: [String: RenderValue] = [:]
        if let primaryTitle { primary["title"] = .string(primaryTitle) }
        if isDestructive { primary["style"] = .string("destructive") }
        var payload: [String: RenderValue] = ["title": .string(title), "primaryAction": .object(primary)]
        if let message { payload["message"] = .string(message) }
        return try await perform("feedback", "confirmAlert", [.object(payload)]) == "true"
    }

    // MARK: - The palette and the launcher

    func closeMainWindow(clearRootSearch: Bool) {
        call("window", "close", [.object(["clearRootSearch": .bool(clearRootSearch)])])
    }

    func popToRoot() { call("window", "popToRoot", []) }
    func clearSearchBar() { call("window", "clearSearchBar", []) }
    func openPreferences() { call("window", "openPreferences", [.string("extension")]) }

    /// Another of this plugin's commands; a plugin can't launch another's.
    func launchCommand(
        _ commandName: String, background: Bool, arguments: [String: String],
        context: [String: PluginValue]
    ) async throws {
        let type = background ? ExtensionLaunchType.background : ExtensionLaunchType.userInitiated
        let options: [String: RenderValue] = [
            "name": .string(commandName), "extensionName": .string(name),
            "type": .string(type.rawValue),
            "arguments": .object(arguments.mapValues(RenderValue.string)),
            "context": .object(context.mapValues(\.renderValue))
        ]
        _ = try await perform("system", "launchCommand", [.object(options)])
    }

    /// Nil puts back the manifest's subtitle.
    func updateCommandMetadata(subtitle: String?) {
        call(
            "system", "updateCommandMetadata",
            [.object(["subtitle": subtitle.map(RenderValue.string) ?? .null])])
    }

    // MARK: - Applications

    func applications(forPath path: String?) async throws -> [PluginApplication] {
        let json = try await perform("system", "applications", path.map { [.string($0)] } ?? [])
        return RenderValue.arguments(from: json).compactMap(PluginApplication.init)
    }

    func defaultApplication(for path: String) async throws -> PluginApplication? {
        let json = try await perform("system", "defaultApplication", [.string(path)])
        return PluginApplication(RenderValue(json: Self.object(json)))
    }

    func frontmostApplication() async throws -> PluginApplication? {
        let json = try await perform("system", "frontmostApplication", [])
        return PluginApplication(RenderValue(json: Self.object(json)))
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
        let redirect = redirectURI ?? "\(appScheme)://oauth?plugin=\(name.dropFirst(PluginManifest.hostNamePrefix.count))"
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
        let redirect = try await perform("oauth", "authorize", [.string(request.url), .string(scheme)])
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

    /// Stored in the shape Raycast's `setTokens` keeps, under the plugin's host name.
    func setOAuthTokens(
        provider: String, accessToken: String, refreshToken: String?, idToken: String?, expiresIn: Double?,
        scope: String?
    ) async throws {
        var tokens: [String: Any] = [
            "accessToken": accessToken, "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        tokens["refreshToken"] = refreshToken
        tokens["idToken"] = idToken
        tokens["expiresIn"] = expiresIn
        tokens["scope"] = scope
        _ = try await perform("oauth", "setTokens", [.string(provider), .string(ExtensionJSON.string(from: tokens))])
    }

    func oauthTokens(provider: String) async throws -> PluginOAuthTokens? {
        let stored = try await perform("oauth", "getTokens", [.string(provider)])
        guard let data = stored.data(using: .utf8), !data.isEmpty,
            let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = fields["accessToken"] as? String
        else { return nil }
        let updatedAt = (fields["updatedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        return PluginOAuthTokens(
            accessToken: accessToken, refreshToken: fields["refreshToken"] as? String,
            idToken: fields["idToken"] as? String, expiresIn: fields["expiresIn"] as? Double,
            scope: fields["scope"] as? String, updatedAt: updatedAt.timeIntervalSince1970)
    }

    func removeOAuthTokens(provider: String) async throws {
        _ = try await perform("oauth", "setTokens", [.string(provider), .null])
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

    private func toastPayload(
        _ style: String, _ title: String, _ message: String?, _ actionTitle: String?,
        _ token: String?
    ) -> RenderValue {
        var payload: [String: RenderValue] = ["style": .string(style), "title": .string(title)]
        if let message { payload["message"] = .string(message) }
        if let token {
            payload["primaryAction"] = .object([
                "title": .string(actionTitle ?? String(localized: "Open")), "token": .string(token)
            ])
        }
        return .object(payload)
    }

    /// Fire and forget: a failure is the plugin's, reported on its screen.
    private func call(_ api: String, _ method: String, _ arguments: [RenderValue]) {
        guard let hostAPI else { return }
        let report = onError
        Task { @MainActor in
            do {
                _ = try await hostAPI.perform(api: api, method: method, arguments: arguments)
            } catch {
                report(error)
            }
        }
    }

    private func perform(
        _ api: String, _ method: String, _ arguments: [RenderValue]
    ) async throws -> String {
        guard let hostAPI else { throw ExtensionHostError.noActiveExtension }
        return try await hostAPI.perform(api: api, method: method, arguments: arguments)
    }

    private static func value(_ stored: ExtensionStorage.StoredValue) -> PluginValue {
        switch stored {
        case .string(let text): .string(text)
        case .number(let number): .number(number)
        case .bool(let flag): .bool(flag)
        }
    }

    private static func object(_ json: String) -> Any {
        guard let data = json.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return NSNull() }
        return value
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
struct PluginOAuthTokens {
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
struct PluginApplication {
    var name: String
    var path: String
    var bundleID: String?
}

extension PluginApplication {
    init?(_ value: RenderValue) {
        guard let fields = value.objectValue, let name = fields["name"]?.stringValue,
            let path = fields["path"]?.stringValue
        else { return nil }
        self.init(name: name, path: path, bundleID: fields["bundleId"]?.stringValue)
    }
}

extension PluginEnvironment {
    static func make(
        plugin: PluginManifest, command: String, storage: ExtensionStorage, hostAPI: ExtensionHostAPI,
        appScheme: String, onInvalidate: @escaping () -> Void, onError: @escaping (any Error) -> Void
    ) -> PluginEnvironment {
        let environment = PluginEnvironment()
        environment.appScheme = appScheme
        environment.name = plugin.hostName
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
