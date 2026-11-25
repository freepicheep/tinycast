// What Return, ⌘Return, a shortcut and ⌘K run: buttons and links in a `.contextMenu` or a
// `.toolbar`. Tinycast performs an opening or a copy itself, after checking the manifest allows it.

import Foundation
import _TinycastHost

public enum ButtonRole {
    case destructive
    case cancel
}

func _button(
    _ title: String, systemImage: String? = nil, role: ButtonRole? = nil, effect: PluginEffect? = nil,
    run: (() -> Void)? = nil
) -> _Part {
    var part = _Part(.button)
    part.title = title
    part.icon = systemImage.map { PluginImage.symbol($0, color: nil) }
    if let role { part.role = role == .destructive ? PluginActionRole.destructive : PluginActionRole.cancel }
    part.effect = effect
    part.run = run
    return part
}

/// Runs the plugin's own code. Start awaited work with `Task { … }`, as in SwiftUI.
public struct Button: _PrimitiveView {
    let part: _Part

    public init(
        _ title: String, systemImage: String? = nil, role: ButtonRole? = nil, action: @escaping () -> Void
    ) {
        part = _button(title, systemImage: systemImage, role: role, run: action)
    }

    /// Its title and icon from `label`: a `Label` or a `Text`.
    public init<Content: View>(
        role: ButtonRole? = nil, action: @escaping () -> Void, @ViewBuilder label: () -> Content
    ) {
        let drawn = _resolve(label()).first
        var made = _button(drawn?.plainTitle ?? "", role: role, run: action)
        made.icon = drawn?.icon
        part = made
    }

    public var _parts: [_Part] { [part] }
}

/// Opens a web address, a file path or an app link the manifest allows, then closes the palette.
public struct Link: _PrimitiveView {
    let part: _Part

    public init(_ title: String, destination: URL) {
        part = _button(title, effect: .openURL(destination.absoluteString, application: nil))
    }

    public init(_ title: String, destination: String) {
        part = _button(title, effect: .openURL(destination, application: nil))
    }

    public var _parts: [_Part] { [part] }
}

/// Pushes `destination` onto the command's stack; Escape comes back.
public struct NavigationLink: _PrimitiveView {
    let part: _Part

    public init<Destination: View>(
        _ title: String, systemImage: String? = nil, @ViewBuilder destination: @escaping () -> Destination
    ) {
        part = _button(title, systemImage: systemImage, effect: .push) {
            let view = destination()
            _push(_Entry { _resolve(view) })
        }
    }

    public init<Destination: View, Content: View>(
        @ViewBuilder destination: @escaping () -> Destination, @ViewBuilder label: () -> Content
    ) {
        let drawn = _resolve(label()).first
        var made = _button(drawn?.plainTitle ?? "", effect: .push) {
            let view = destination()
            _push(_Entry { _resolve(view) })
        }
        made.icon = drawn?.icon
        part = made
    }

    public var _parts: [_Part] { [part] }
}

/// Copies `text`, closes the palette and says so. Needs no permission: the user asked for it.
/// `concealed` keeps it out of clipboard history, for a password.
public struct CopyButton: _PrimitiveView {
    let part: _Part

    public init(_ title: String = "Copy to Clipboard", text: String, concealed: Bool = false) {
        part = _button(title, effect: .copy(text, concealed: concealed))
    }

    public var _parts: [_Part] { [part] }
}

/// Hands `item` on: Tinycast copies it.
public struct ShareLink: _PrimitiveView {
    let part: _Part

    public init(_ title: String = "Copy Link", item: URL) {
        part = _button(title, effect: .copy(item.absoluteString, concealed: false))
    }

    public init(_ title: String = "Copy Link", item: String) {
        part = _button(title, effect: .copy(item, concealed: false))
    }

    public var _parts: [_Part] { [part] }
}

/// Pastes `text` into the app that was in front before the palette opened.
public struct PasteButton: _PrimitiveView {
    let part: _Part

    public init(_ title: String = "Paste in Active App", text: String) {
        part = _button(title, effect: .paste(text))
    }

    public var _parts: [_Part] { [part] }
}

/// Reveals a file or folder in Finder.
public struct ShowInFinderButton: _PrimitiveView {
    let part: _Part

    public init(_ title: String = "Show in Finder", path: String) {
        part = _button(title, effect: .revealInFinder(path))
    }

    public var _parts: [_Part] { [part] }
}

/// Asks which app should open a file.
public struct OpenWithButton: _PrimitiveView {
    let part: _Part

    public init(_ title: String = "Open With", path: String) {
        part = _button(title, effect: .openWith(path))
    }

    public var _parts: [_Part] { [part] }
}

/// Moves files to the Trash, then runs `onTrash`. The user chooses it; a plugin has no other way
/// to remove a file.
public struct TrashButton: _PrimitiveView {
    let part: _Part

    public init(_ title: String = "Move to Trash", paths: [String], onTrash: (() -> Void)? = nil) {
        part = _button(title, role: .destructive, effect: .trash(paths), run: onTrash)
    }

    public var _parts: [_Part] { [part] }
}

/// Actions, or menu-bar items, one level down.
public struct Menu: _PrimitiveView {
    let part: _Part

    public init<Content: View>(_ title: String, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        var made = _button(title, systemImage: systemImage, effect: .menu)
        made.kind = .menu
        made.children = _resolve(content())
        part = made
    }

    public var _parts: [_Part] { [part] }
}

/// A key for `keyboardShortcut`: a character, or one of the named keys.
public struct KeyEquivalent: ExpressibleByStringLiteral {
    let value: PluginKey

    public init(stringLiteral character: String) {
        value = .character(character.lowercased())
    }

    init(key: PluginKey) {
        value = key
    }

    public static let `return` = KeyEquivalent(key: .returnKey)
    public static let delete = KeyEquivalent(key: .delete)
    public static let deleteForward = KeyEquivalent(key: .deleteForward)
    public static let tab = KeyEquivalent(key: .tab)
    public static let space = KeyEquivalent(key: .space)
    public static let escape = KeyEquivalent(key: .escape)
    public static let upArrow = KeyEquivalent(key: .upArrow)
    public static let downArrow = KeyEquivalent(key: .downArrow)
    public static let leftArrow = KeyEquivalent(key: .leftArrow)
    public static let rightArrow = KeyEquivalent(key: .rightArrow)
}

/// The modifier keys a shortcut holds.
public struct EventModifiers: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = EventModifiers(rawValue: 1)
    public static let shift = EventModifiers(rawValue: 2)
    public static let option = EventModifiers(rawValue: 4)
    public static let control = EventModifiers(rawValue: 8)

    var wire: [PluginModifier] {
        var modifiers: [PluginModifier] = []
        if contains(.command) { modifiers.append(.command) }
        if contains(.shift) { modifiers.append(.shift) }
        if contains(.option) { modifiers.append(.option) }
        if contains(.control) { modifiers.append(.control) }
        return modifiers
    }
}
