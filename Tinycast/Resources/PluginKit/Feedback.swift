// The clipboard, and the feedback a command gives while it works or after.

import Foundation
import _TinycastHost

/// Writing to the clipboard and pasting need no permission: the user asked for them. Reading it
/// is `NSPasteboard` in `import AppKit`, with the clipboard permission.
public enum Clipboard {
    /// `concealed` keeps the text out of clipboard history, for a password or a token.
    public static func copy(_ text: String, concealed: Bool = false) {
        _environment?.copy(text, concealed: concealed)
    }

    /// Pastes into the app that was in front before the palette opened.
    public static func paste(_ text: String) {
        _environment?.paste(text)
    }

    public static func clear() {
        _environment?.clearClipboard()
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
    /// The token the host sends back for the button, made again whenever the action changes.
    private var token: String?

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
        case .success: "success"
        case .failure: "failure"
        case .animated: "animated"
        }
    }

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

/// Shows a short message, closing the palette.
public func showHUD(_ text: String) {
    _environment?.showHUD(text)
}

/// Asks the user, the way the rest of Tinycast asks; true when they confirm.
public func confirmAlert(
    title: String, message: String? = nil, primaryTitle: String? = nil, destructive: Bool = false
) async -> Bool {
    guard let environment = _environment else { return false }
    return (try? await environment.confirm(
        title: title, message: message, primaryTitle: primaryTitle, isDestructive: destructive)) ?? false
}
