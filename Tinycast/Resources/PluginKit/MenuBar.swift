// A menu-bar command's body: the status item, and the menu it opens.

import Foundation
import _TinycastHost

/// The status item a `Plugin.menuBar` command shows: a title, an icon or both, and its menu.
public struct MenuBarExtra: _PrimitiveView {
    var props: [String: PluginValue] = [:]
    let items: [PluginNode]
    var task: _Task?

    public init<Content: View>(
        _ title: String? = nil, systemImage: String? = nil, tooltip: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        if let title { props["title"] = .string(title) }
        if let systemImage { props["icon"] = Image(systemName: systemImage).value }
        if let tooltip { props["tooltip"] = .string(tooltip) }
        items = _menuItems(_nodes(content()))
    }

    public var _elements: [_Element] { [.screen(_node("MenuBarExtra", props, children: items), task)] }

    /// While true, the item keeps its last menu and the command keeps running.
    public func loading(_ isLoading: Bool) -> MenuBarExtra {
        var copy = self
        copy.props["isLoading"] = .bool(isLoading)
        return copy
    }

    public func task(_ action: @escaping () async -> Void) -> MenuBarExtra {
        var copy = self
        copy.task = _Task(key: "", run: action)
        return copy
    }
}

/// One entry of a menu-bar command's menu.
public struct MenuItem: _PrimitiveView {
    var props: [String: PluginValue]

    public init(
        _ title: String, subtitle: String? = nil, systemImage: String? = nil, tooltip: String? = nil,
        action: (() -> Void)? = nil
    ) {
        props = ["title": .string(title)]
        if let subtitle { props["subtitle"] = .string(subtitle) }
        if let systemImage { props["icon"] = Image(systemName: systemImage).value }
        if let tooltip { props["tooltip"] = .string(tooltip) }
        if let action { props["onAction"] = _handler { _ in action() } }
    }

    public var _elements: [_Element] { [.node(_node("MenuBarExtra.Item", key: _title, props))] }

    var _title: String? {
        if case .string(let title) = props["title"] { return title }
        return nil
    }

    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> MenuItem {
        var copy = self
        copy.props["shortcut"] = .object([
            "key": .string(key.name), "modifiers": .array(modifiers.names.map { PluginValue.string($0) })
        ])
        return copy
    }

    /// Shown in this item's place while ⌥ is held.
    public func alternate(_ item: MenuItem) -> MenuItem {
        var copy = self
        copy.props["alternate"] = .node(_node("MenuBarExtra.Item", key: item._title, item.props))
        return copy
    }
}

/// Items one level down.
public struct Menu: _PrimitiveView {
    let node: PluginNode

    public init<Content: View>(_ title: String, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        var props: [String: PluginValue] = ["title": .string(title)]
        if let systemImage { props["icon"] = Image(systemName: systemImage).value }
        node = _node("MenuBarExtra.Submenu", key: title, props, children: _menuItems(_nodes(content())))
    }

    public var _elements: [_Element] { [.node(node)] }
}

/// A menu's `Section` and `Divider` take its names.
func _menuItems(_ nodes: [PluginNode]) -> [PluginNode] {
    nodes.map { node in
        var node = node
        switch node.type {
        case "Section":
            node.type = "MenuBarExtra.Section"
            node.children = _menuItems(node.children)
        case "Separator":
            node.type = "MenuBarExtra.Separator"
        default:
            break
        }
        return node
    }
}
