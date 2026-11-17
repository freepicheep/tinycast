import _TinycastHost

/// One entry in a row's actions: what ↵, ⌘↵ and the ⌘K menu run.
public struct Action: _ActionConvertible {
    var action: PluginAction

    init(_ title: String, systemImage: String?, isDestructive: Bool = false, kind: PluginActionKind) {
        action = PluginAction(
            title: title, systemImage: systemImage, shortcutKey: nil, modifiers: [],
            isDestructive: isDestructive, kind: kind)
    }

    public var _action: Action { self }
}

/// Anything an `actions` builder takes. Underscored: a plugin writes buttons and links.
public protocol _ActionConvertible {
    var _action: Action { get }
}

extension _ActionConvertible {
    /// Runs the action from anywhere its key is pressed while its row is selected.
    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> Action {
        var copy = _action
        copy.action.shortcutKey = key.name
        copy.action.modifiers = modifiers.names
        return copy
    }
}

public enum ButtonRole {
    case destructive
    case cancel
}

/// An action that runs the plugin's own code.
public struct Button: _ActionConvertible {
    public let _action: Action

    public init(
        _ title: String, systemImage: String? = nil, role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        _action = Action(
            title, systemImage: systemImage, isDestructive: role == .destructive,
            kind: .perform { action() })
    }
}

/// Opens a web address or a file path with its default app.
public struct Link: _ActionConvertible {
    public let _action: Action

    public init(_ title: String, destination: String) {
        _action = Action(title, systemImage: "arrow.up.forward.app", kind: .open(destination))
    }
}

/// Pushes `destination` onto the command's stack; Escape comes back.
public struct NavigationLink: _ActionConvertible {
    public let _action: Action

    public init<Destination: View>(
        _ title: String, systemImage: String? = nil,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        _action = Action(
            title, systemImage: systemImage ?? "arrow.right",
            kind: .perform {
                let view = destination()
                _push(_Entry { _resolve(view) })
            })
    }
}

/// Copies `text` when chosen. Needs no permission: the user asked for it.
public struct CopyButton: _ActionConvertible {
    public let _action: Action

    public init(_ title: String = "Copy to Clipboard", text: String) {
        _action = Action(title, systemImage: "doc.on.doc", kind: .copy(text))
    }
}

/// Pastes `text` into the app that was frontmost before the palette opened.
public struct PasteButton: _ActionConvertible {
    public let _action: Action

    public init(_ title: String = "Paste to Active App", text: String) {
        _action = Action(title, systemImage: "text.insert", kind: .paste(text))
    }
}

@resultBuilder
public enum ActionBuilder {
    public static func buildExpression<A: _ActionConvertible>(_ action: A) -> [Action] {
        [action._action]
    }
    public static func buildBlock(_ parts: [Action]...) -> [Action] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [Action]?) -> [Action] { part ?? [] }
    public static func buildEither(first part: [Action]) -> [Action] { part }
    public static func buildEither(second part: [Action]) -> [Action] { part }
    public static func buildArray(_ parts: [[Action]]) -> [Action] { parts.flatMap { $0 } }
}

/// A key for `keyboardShortcut`: a character, or one of the named keys.
public struct KeyEquivalent: ExpressibleByStringLiteral {
    let name: String

    public init(stringLiteral value: String) { name = value.lowercased() }
    init(name: String) { self.name = name }

    public static let `return` = KeyEquivalent(name: "return")
    public static let delete = KeyEquivalent(name: "delete")
    public static let tab = KeyEquivalent(name: "tab")
    public static let space = KeyEquivalent(name: "space")
    public static let upArrow = KeyEquivalent(name: "up")
    public static let downArrow = KeyEquivalent(name: "down")
}

public struct EventModifiers: ExpressibleByArrayLiteral {
    let names: [String]

    init(names: [String]) { self.names = names }
    public init(arrayLiteral elements: EventModifiers...) {
        var names: [String] = []
        for element in elements {
            for name in element.names where !names.contains(name) { names.append(name) }
        }
        self.names = names
    }

    public static let command = EventModifiers(names: ["command"])
    public static let shift = EventModifiers(names: ["shift"])
    public static let option = EventModifiers(names: ["option"])
    public static let control = EventModifiers(names: ["control"])
}
