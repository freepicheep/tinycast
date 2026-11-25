// SwiftUI's modifiers, as Tinycast draws them. A row modifier applies to each row it's given (all of
// a `ForEach`'s), a screen modifier to the screen; bare rows with a screen modifier become a list.

import Foundation
import _TinycastHost

extension View {
    func _rows(_ change: (inout _Part) -> Void) -> _Parts {
        var parts = _resolve(self)
        for index in parts.indices {
            switch parts[index].kind {
            case .row, .text, .button, .menu, .field, .picker, .labeled:
                change(&parts[index])
            default:
                break
            }
        }
        return _Parts(_parts: parts)
    }

    func _screens(_ change: (_Screen) -> Void) -> _Parts {
        var parts = _resolve(self)
        if !parts.contains(where: { $0.kind == .screen }) { parts = [_Screen(.list, content: parts).part] }
        for part in parts {
            if let screen = part.screen { change(screen) }
        }
        return _Parts(_parts: parts)
    }

    // MARK: Rows

    /// An empty string leaves the row without one.
    public func subtitle(_ text: String) -> _Parts { _rows { $0.subtitle = text.isEmpty ? nil : Text(text).value } }
    public func subtitle(_ text: Text) -> _Parts { _rows { $0.subtitle = text.value } }

    /// Trailing content, as SwiftUI's list badges: a count, text, a label, a tag or an icon.
    public func badge(_ count: Int) -> _Parts { _rows { $0.accessories.append(.count(count)) } }
    public func badge(_ text: String) -> _Parts { _rows { $0.accessories.append(.text(Text(text).value)) } }
    public func badge(_ text: Text) -> _Parts { _rows { $0.accessories.append(.text(text.value)) } }
    public func badge(_ tag: Tag) -> _Parts {
        _rows { $0.accessories.append(.tag(tag.text, color: tag.color?.value)) }
    }
    public func badge(_ image: Image) -> _Parts { _rows { $0.accessories.append(.icon(image.value, tooltip: nil)) } }

    public func badge(_ label: Label) -> _Parts {
        _rows { row in
            if let icon = label.icon {
                row.accessories.append(.label(label.title.value, icon: icon.value))
            } else {
                row.accessories.append(.text(label.title.value))
            }
        }
    }

    /// More words Tinycast's search matches the row by, besides its title and subtitle.
    public func searchKeywords(_ words: String...) -> _Parts { _rows { $0.keywords += words } }
    public func searchKeywords(_ words: [String]) -> _Parts { _rows { $0.keywords += words } }

    /// Tints the row's symbol.
    public func foregroundStyle(_ color: Color) -> _Parts {
        _rows { row in
            if case .symbol(let name, _)? = row.icon { row.icon = .symbol(name, color: color.value) }
        }
    }

    /// What a `Picker` or a list's `selection` sets when this row is chosen.
    public func tag<Value: Hashable>(_ tag: Value) -> _Parts { _rows { $0.tag = AnyHashable(tag) } }

    /// Keeps the selection on this row while its content changes; a field's name in a form.
    public func id<ID: Hashable>(_ id: ID) -> _Parts { _rows { $0.id = "\(id)" } }

    /// The row's actions: the first runs on Return, the second on ⌘Return, all are in ⌘K.
    public func contextMenu<Content: View>(@ViewBuilder menuItems: () -> Content) -> _Parts {
        let actions = _resolve(menuItems())
        return _rows { $0.actions += actions }
    }

    /// Shown beside the list while this row is selected, in a list that `.showsDetail()`.
    public func detail(_ content: () -> Detail) -> _Parts {
        let screen = content().screen
        return _rows { $0.detail = screen }
    }

    /// A tooltip: a row's icon's, a menu item's, a field's note, a menu-bar item's.
    public func help(_ text: String) -> _Parts {
        var parts = _resolve(self)
        for index in parts.indices {
            parts[index].tooltip = text
            parts[index].screen?.tooltip = text
        }
        return _Parts(_parts: parts)
    }

    /// A placeholder look while content loads: `.redacted(reason: .placeholder)`.
    public func redacted(reason: RedactionReasons) -> _Parts {
        let isRedacted = reason.contains(.placeholder)
        var parts = _resolve(self)
        for index in parts.indices {
            parts[index].isRedacted = isRedacted
            parts[index].screen?.isRedacted = isRedacted
        }
        return _Parts(_parts: parts)
    }

    // MARK: Buttons and menu items

    /// Runs the action from anywhere while its row is selected, or while its form is open.
    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> _Parts {
        _rows { $0.shortcut = PluginShortcut(key: key.value, modifiers: modifiers.wire) }
    }

    /// Shown in a menu-bar item's place while ⌥ is held.
    public func alternate<Content: View>(@ViewBuilder _ content: () -> Content) -> _Parts {
        let alternate = _resolve(content())
        return _rows { $0.alternate = alternate }
    }

    // MARK: Fields

    /// A problem with the field's value, drawn under it; nil clears it.
    public func fieldError(_ message: String?) -> _Parts { _rows { $0.error = message } }

    /// Where the form's focus starts.
    public func defaultFocus() -> _Parts { _rows { $0.focusedByDefault = true } }

    // MARK: Screens

    public func navigationTitle(_ title: String) -> _Parts { _screens { $0.title = title } }

    /// The plugin filters its own rows from `text`, which each keystroke sets.
    public func searchable(text: Binding<String>, prompt: String? = nil) -> _Parts {
        _screens { screen in
            screen.search = text
            screen.searchPrompt = prompt
        }
    }

    /// The search field's prompt, with Tinycast still filtering the rows.
    public func searchable(prompt: String) -> _Parts { _screens { $0.searchPrompt = prompt } }

    /// Pickers beside the search field, and the screen's own actions: an empty list's, a
    /// detail's, a form's (the first runs on ⌘Return).
    public func toolbar<Content: View>(@ViewBuilder content: () -> Content) -> _Parts {
        let items = _resolve(content())
        return _screens { $0.toolbar += items }
    }

    /// What an empty list shows: a `ContentUnavailableView`.
    public func overlay<Content: View>(@ViewBuilder content: () -> Content) -> _Parts {
        let overlay = _resolve(content())
        return _screens { $0.overlay += overlay }
    }

    /// The spinner in the search field, while the command works.
    public func loading(_ isLoading: Bool) -> _Parts { _screens { $0.isLoading = isLoading } }

    /// The selected row's `.detail` beside the rows.
    public func showsDetail(_ isShowing: Bool = true) -> _Parts { _screens { $0.showsDetail = isShowing } }

    /// Runs once when the screen first appears, and is cancelled when it leaves the stack.
    public func task(_ action: @escaping () async -> Void) -> _Parts {
        _screens { $0.task = _Task(key: "", run: action) }
    }

    /// Like `task(_:)`, cancelled and started again whenever `id` changes.
    public func task<ID: Equatable>(id: ID, _ action: @escaping () async -> Void) -> _Parts {
        _screens { $0.task = _Task(key: "\(id)", run: action) }
    }

    /// ⌘R runs `action`, listed in the screen's actions as Refresh.
    public func refreshable(action: @escaping () async -> Void) -> _Parts {
        _screens { $0.refresh = action }
    }
}

/// Why content is drawn as a placeholder.
public struct RedactionReasons: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let placeholder = RedactionReasons(rawValue: 1)
}
