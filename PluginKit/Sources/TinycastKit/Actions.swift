// What ↵, ⌘↵, a shortcut and the ⌘K menu run: each is an `Action` component.


/// One entry in a row's, a screen's or a form's actions.
public struct Action: _ActionConvertible {
    var props: [String: PluginValue]

    init(_ title: String, systemImage: String?, isDestructive: Bool = false, run: @escaping () -> Void) {
        props = ["title": .string(title), "onAction": _handler { _ in run() }]
        if let systemImage { props["icon"] = Image(systemName: systemImage).value }
        if isDestructive { props["style"] = .string("destructive") }
    }

    init(props: [String: PluginValue]) {
        self.props = props
    }

    public var _actionNodes: [PluginNode] { [_node("Action", key: _key, props)] }

    var _key: String? {
        if case .string(let title) = props["title"] { return title }
        return nil
    }
}

/// Anything an `actions` builder takes. Underscored: a plugin writes buttons and links.
public protocol _ActionConvertible {
    var _actionNodes: [PluginNode] { get }
}

extension _ActionConvertible {
    /// Runs the action from anywhere its key is pressed while its row is selected.
    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> Action {
        var props = _actionNodes.first?.props ?? [:]
        props["shortcut"] = .object([
            "key": .string(key.name), "modifiers": .array(modifiers.names.map { PluginValue.string($0) })
        ])
        return Action(props: props)
    }
}

public enum ButtonRole {
    case destructive
    case cancel
}

/// An action that runs the plugin's own code. Start awaited work with `Task { … }`, as in SwiftUI.
public struct Button: _ActionConvertible {
    let action: Action

    public init(
        _ title: String, systemImage: String? = nil, role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.action = Action(title, systemImage: systemImage, isDestructive: role == .destructive, run: action)
    }

    public var _actionNodes: [PluginNode] { action._actionNodes }
}

/// Opens a web address, a file path or an app link the manifest allows, then closes the palette.
public struct Link: _ActionConvertible {
    let action: Action

    public init(_ title: String = "Open in Browser", destination: String, application: String? = nil) {
        action = Action(title, systemImage: "arrow.up.forward.app") {
            open(destination, application: application)
            closeMainWindow()
        }
    }

    public var _actionNodes: [PluginNode] { action._actionNodes }
}

/// Pushes `destination` onto the command's stack; Escape comes back.
public struct NavigationLink: _ActionConvertible {
    let action: Action

    public init<Destination: View>(
        _ title: String, systemImage: String? = nil,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        action = Action(title, systemImage: systemImage ?? "arrow.right") {
            let view = destination()
            _push(_Entry { _resolve(view) })
        }
    }

    public var _actionNodes: [PluginNode] { action._actionNodes }
}

/// Copies `text` when chosen, then closes the palette and says so. Needs no permission: the user
/// asked for it. `concealed` keeps it out of clipboard history, for a password.
public struct CopyButton: _ActionConvertible {
    let action: Action

    public init(_ title: String = "Copy to Clipboard", text: String, concealed: Bool = false) {
        action = Action(title, systemImage: "doc.on.doc") {
            Clipboard.copy(text, concealed: concealed)
            closeMainWindow()
            showHUD("Copied to Clipboard")
        }
    }

    public var _actionNodes: [PluginNode] { action._actionNodes }
}

/// Pastes `text` into the app that was frontmost before the palette opened.
public struct PasteButton: _ActionConvertible {
    let action: Action

    public init(_ title: String = "Paste in Active App", text: String) {
        action = Action(title, systemImage: "text.insert") { Clipboard.paste(text) }
    }

    public var _actionNodes: [PluginNode] { action._actionNodes }
}

/// Reveals a file or folder in Finder.
public struct ShowInFinderButton: _ActionConvertible {
    let action: Action

    public init(_ title: String = "Show in Finder", path: String) {
        action = Action(title, systemImage: "folder") { showInFinder(path) }
    }

    public var _actionNodes: [PluginNode] { action._actionNodes }
}

/// Asks which app should open a file.
public struct OpenWithButton: _ActionConvertible {
    let action: Action

    public init(_ title: String = "Open With", path: String) {
        action = Action(title, systemImage: "macwindow") { _environment?.openWith(path) }
    }

    public var _actionNodes: [PluginNode] { action._actionNodes }
}

/// Moves files to the Trash. The user chooses it; a plugin has no other way to remove a file.
public struct TrashButton: _ActionConvertible {
    let action: Action

    public init(_ title: String = "Move to Trash", paths: [String], onTrash: (() -> Void)? = nil) {
        action = Action(title, systemImage: "trash", isDestructive: true) {
            _environment?.trash(paths)
            onTrash?()
        }
    }

    public var _actionNodes: [PluginNode] { action._actionNodes }
}

/// A form's submit action: saves its `storeValue` fields, then runs `action`.
public struct SubmitButton: _ActionConvertible {
    let action: Action

    public init(_ title: String = "Submit", systemImage: String? = nil, action: @escaping () -> Void) {
        self.action = Action(title, systemImage: systemImage ?? "checkmark.circle") {
            _storeFormValues()
            action()
        }
    }

    public var _actionNodes: [PluginNode] { action._actionNodes }
}

/// Actions under a heading in the ⌘K menu.
public struct ActionSection: _ActionConvertible {
    let node: PluginNode

    public init(_ title: String? = nil, @ActionBuilder _ content: () -> [PluginNode]) {
        var props: [String: PluginValue] = [:]
        if let title { props["title"] = .string(title) }
        node = _node("ActionPanel.Section", key: title, props, children: content())
    }

    public var _actionNodes: [PluginNode] { [node] }
}

/// Actions one level down in the ⌘K menu.
public struct ActionMenu: _ActionConvertible {
    let node: PluginNode

    public init(_ title: String, systemImage: String? = nil, @ActionBuilder _ content: () -> [PluginNode]) {
        var props: [String: PluginValue] = ["title": .string(title)]
        if let systemImage { props["icon"] = Image(systemName: systemImage).value }
        node = _node("ActionPanel.Submenu", key: title, props, children: content())
    }

    public var _actionNodes: [PluginNode] { [node] }
}

func _actionPanel(_ actions: [PluginNode]) -> PluginNode {
    _node("ActionPanel", children: actions)
}

@resultBuilder
public enum ActionBuilder {
    public static func buildExpression<A: _ActionConvertible>(_ action: A) -> [PluginNode] {
        action._actionNodes
    }
    public static func buildBlock(_ parts: [PluginNode]...) -> [PluginNode] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [PluginNode]?) -> [PluginNode] { part ?? [] }
    public static func buildEither(first part: [PluginNode]) -> [PluginNode] { part }
    public static func buildEither(second part: [PluginNode]) -> [PluginNode] { part }
    public static func buildArray(_ parts: [[PluginNode]]) -> [PluginNode] { parts.flatMap { $0 } }
}

/// A key for `keyboardShortcut`: a character, or one of the named keys.
public struct KeyEquivalent: ExpressibleByStringLiteral {
    let name: String

    public init(stringLiteral value: String) { name = value.lowercased() }
    init(name: String) { self.name = name }

    public static let `return` = KeyEquivalent(name: "return")
    public static let delete = KeyEquivalent(name: "backspace")
    public static let deleteForward = KeyEquivalent(name: "deleteForward")
    public static let tab = KeyEquivalent(name: "tab")
    public static let space = KeyEquivalent(name: "space")
    public static let upArrow = KeyEquivalent(name: "arrowUp")
    public static let downArrow = KeyEquivalent(name: "arrowDown")
    public static let leftArrow = KeyEquivalent(name: "arrowLeft")
    public static let rightArrow = KeyEquivalent(name: "arrowRight")
}

/// Modifier keys, as Raycast's shortcuts name them.
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

    public static let command = EventModifiers(names: ["cmd"])
    public static let shift = EventModifiers(names: ["shift"])
    public static let option = EventModifiers(names: ["opt"])
    public static let control = EventModifiers(names: ["ctrl"])
}
