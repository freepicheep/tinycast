// The clipboard, storage that outlives a command, and the feedback a command gives.


/// Writing to the clipboard and pasting need no permission: the user asked for them. Reading it
/// needs the `clipboard` permission.
public enum Clipboard {
    /// The clipboard's text, if it holds any.
    public static func readText() async throws -> String? {
        try await _call("clipboard", "readText", []).text
    }

    /// `concealed` keeps the text out of clipboard history, for a password or a token.
    public static func copy(_ text: String, concealed: Bool = false) {
        _environment?.copy(text, concealed: concealed)
    }

    /// Pastes into the app that was frontmost before the palette opened.
    public static func paste(_ text: String) {
        _environment?.paste(text)
    }

    public static func clear() {
        _environment?.clearClipboard()
    }
}

/// The plugin's own key–value storage: strings, numbers and booleans, kept between launches and
/// shared by its commands. `@AppStorage` reads and writes the same keys.
public enum LocalStorage {
    public static func item<Value: AppStorageValue>(_ key: String, as type: Value.Type = Value.self) -> Value? {
        _environment?.storedValue(forKey: key).flatMap { Value(_stored: $0) }
    }

    public static func setItem<Value: AppStorageValue>(_ key: String, _ value: Value) {
        _environment?.setStoredValue(value._stored, forKey: key)
    }

    public static func removeItem(_ key: String) {
        _environment?.setStoredValue(nil, forKey: key)
    }

    public static func allItems() -> [String: PluginValue] {
        _environment?.storedValues() ?? [:]
    }

    public static func clear() {
        _environment?.clearStoredValues()
    }
}

/// Text kept between launches for speed, such as the last fetch; it may be emptied at any time.
public struct Cache {
    let namespace: String

    public init(namespace: String = "default") {
        self.namespace = namespace
    }

    public func get(_ key: String) -> String? {
        _environment?.cachedValue(namespace: namespace, key: key)
    }

    public func set(_ key: String, _ value: String) {
        _environment?.setCachedValue(value, namespace: namespace, key: key)
    }

    public func remove(_ key: String) {
        _environment?.setCachedValue(nil, namespace: namespace, key: key)
    }

    public func has(_ key: String) -> Bool { get(key) != nil }

    public var keys: [String] { _environment?.cachedKeys(namespace: namespace) ?? [] }

    public func clear() {
        _environment?.setCachedValue(nil, namespace: namespace, key: nil)
    }
}

/// A message in the palette's footer while a command works, or after.
public final class Toast {
    public enum Style {
        case success
        case failure
        /// A spinner, until the toast changes or hides.
        case animated
    }

    private var id: Int?

    public var style: Style { didSet { update() } }
    public var title: String { didSet { update() } }
    public var message: String? { didSet { update() } }
    private var actionTitle: String?
    private var action: (() -> Void)?

    init(style: Style, title: String, message: String?, actionTitle: String?, action: (() -> Void)?) {
        self.style = style
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    /// The button the toast shows, which runs `action`.
    public func setAction(_ title: String, _ action: @escaping () -> Void) {
        actionTitle = title
        self.action = action
        token = nil
        update()
    }

    public func hide() {
        guard let id else { return }
        _environment?.hideToast(id)
    }

    var styleName: String {
        switch style {
        case .success: "SUCCESS"
        case .failure: "FAILURE"
        case .animated: "ANIMATED"
        }
    }

    /// The token the host sends back for the button, made again whenever the action changes.
    private var token: String?

    private func actionToken() -> String? {
        guard let action else { return nil }
        if token == nil { token = _environment?.toastToken { action() } }
        return token
    }

    func show() async {
        let token = actionToken()
        id = try? await _environment?.showToast(
            style: styleName, title: title, message: message, actionTitle: actionTitle, actionToken: token)
    }

    private func update() {
        guard let id else { return }
        _environment?.updateToast(
            id, style: styleName, title: title, message: message, actionTitle: actionTitle,
            actionToken: actionToken())
    }
}

/// Shows a toast and hands it back, so the command can change or hide it as its work goes on.
@discardableResult
public func showToast(
    _ style: Toast.Style = .success, title: String, message: String? = nil, actionTitle: String? = nil,
    action: (() -> Void)? = nil
) async -> Toast {
    let toast = Toast(style: style, title: title, message: message, actionTitle: actionTitle, action: action)
    await toast.show()
    return toast
}
