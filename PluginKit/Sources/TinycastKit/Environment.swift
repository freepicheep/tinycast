// The session's view of Tinycast: storage read from what the launch brought and written through to
// the host, the clipboard, toasts. Every write is a host call, checked there.

@MainActor var _environment: _Environment? { _ended || _launch == nil ? nil : _Environment.shared }
@MainActor var _toastActions: [String: @MainActor () -> Void] = [:]

@MainActor
final class _Environment {
    static let shared = _Environment()

    func invalidate() { _invalidate() }

    // MARK: Storage: a getter reads it synchronously, so the launch brings it and writes go through

    func storedValue(forKey key: String) -> PluginValue? { _launch?.localStorage[key] }

    /// Only strings, numbers and booleans are kept, as in Raycast's `LocalStorage`.
    func setStoredValue(_ value: PluginValue?, forKey key: String) {
        _launch?.localStorage[key] = value
        if let value {
            _send("storage", "set", [.string(key), value])
        } else {
            _send("storage", "remove", [.string(key)])
        }
    }

    func storedValues() -> [String: PluginValue] { _launch?.localStorage ?? [:] }

    func clearStoredValues() {
        _launch?.localStorage = [:]
        _send("storage", "clear", [])
    }

    func cachedValue(namespace: String, key: String) -> String? { _launch?.caches[namespace]?[key] }

    /// A nil value removes the key; a nil key empties the namespace.
    func setCachedValue(_ value: String?, namespace: String, key: String?) {
        if let key {
            _launch?.caches[namespace, default: [:]][key] = value
        } else {
            _launch?.caches[namespace] = nil
        }
        _send(
            "cache", "set",
            [.string(namespace), key.map(PluginValue.string) ?? .null, value.map(PluginValue.string) ?? .null])
    }

    func cachedKeys(namespace: String) -> [String] { (_launch?.caches[namespace] ?? [:]).keys.sorted() }

    /// A form's `storeValue` fields, which the next launch of the command starts from.
    func storeFormValues(_ values: [String: String]) {
        guard !values.isEmpty, let command = _launch?.commandName else { return }
        for (field, value) in values { _launch?.formValues[field] = value }
        _send("form", "store", [.string(command), .object(values.mapValues(PluginValue.string))])
    }

    func storedFormValue(_ field: String) -> String? { _launch?.formValues[field] }

    // MARK: Clipboard: writing needs no permission, since the user asked for it

    func copy(_ text: String, concealed: Bool) {
        _send("clipboard", "copy", [.object(["text": .string(text)]), .object(["concealed": .bool(concealed)])])
    }

    func paste(_ text: String) { _send("clipboard", "paste", [.object(["text": .string(text)])]) }

    func clearClipboard() { _send("clipboard", "clear", []) }

    // MARK: Files a user's action names

    func openWith(_ path: String) { _send("system", "openWith", [.string(path)]) }

    /// Only a `TrashButton` reaches this: the user chose the action that names the paths.
    func trash(_ paths: [String]) { _send("system", "trash", [.array(paths.map(PluginValue.string))]) }

    // MARK: Toasts

    private var nextToastAction = 1

    /// Keeps a toast's action under a token the host sends back when its button is pressed.
    func toastToken(_ action: @escaping @MainActor () -> Void) -> String {
        let token = "plugin-toast-\(nextToastAction)"
        nextToastAction += 1
        _toastActions[token] = action
        return token
    }

    /// The toast's id, for `updateToast` and `hideToast`.
    func showToast(
        style: String, title: String, message: String?, actionTitle: String?, actionToken: String?
    ) async throws -> Int {
        let payload = toastPayload(style, title, message, actionTitle, actionToken)
        return Int(try await _call("feedback", "showToast", [payload]).numberValue ?? 0)
    }

    func updateToast(
        _ id: Int, style: String, title: String, message: String?, actionTitle: String?, actionToken: String?
    ) {
        _send("feedback", "updateToast", [.number(Double(id)), toastPayload(style, title, message, actionTitle, actionToken)])
    }

    func hideToast(_ id: Int) { _send("feedback", "hideToast", [.number(Double(id))]) }

    private func toastPayload(
        _ style: String, _ title: String, _ message: String?, _ actionTitle: String?, _ token: String?
    ) -> PluginValue {
        var payload: [String: PluginValue] = ["style": .string(style), "title": .string(title)]
        if let message { payload["message"] = .string(message) }
        if let token {
            payload["primaryAction"] = .object(["title": .string(actionTitle ?? "Open"), "token": .string(token)])
        }
        return .object(payload)
    }
}
