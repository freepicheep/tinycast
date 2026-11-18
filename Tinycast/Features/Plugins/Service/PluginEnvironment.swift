import Foundation
import Stir

/// The one host object a plugin's session holds. The kit keeps it in a global, so every call is
/// scoped to the session that made it, and a plugin reaches only its own storage. Everything but
/// storage goes through the Extensions host's `ExtensionHostAPI`, which is what a Raycast command
/// reaches too: the same toasts, clipboard, windows and launches.
@StirExport
@MainActor
final class PluginEnvironment {
    private var name = ""
    private var command = ""
    private var urlSchemes: Set<String> = []
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

/// An application as `getApplications` describes it.
@StirExport
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
        onInvalidate: @escaping () -> Void, onError: @escaping (any Error) -> Void
    ) -> PluginEnvironment {
        let environment = PluginEnvironment()
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
