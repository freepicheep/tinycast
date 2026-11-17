import SwiftUI

/// One selectable row of a plugin's list, in the order the screen draws them.
struct PluginRow: Identifiable {
    let id: String
    let item: PluginItem
    let sectionTitle: String?
    /// The first row of its section, which draws the section's header above it.
    let startsSection: Bool
}

/// A running plugin command as a palette screen: its list, or its page of Markdown.
struct PluginCommandScreen: PaletteScreen {
    let plugins: PluginManager
    let vm: PaletteState
    let openActions: () -> Void

    private var list: PluginList? {
        if case .page(.list(let list)) = plugins.screen { return list }
        return nil
    }

    private var detailPage: PluginDetail? {
        if case .page(.detail(let detail)) = plugins.screen { return detail }
        return nil
    }

    /// A list that searches for itself gets its rows as they are; any other is filtered here.
    var rows: [PluginRow] {
        guard let list else { return [] }
        let query = list.search == nil ? ActionMenuSearchQuery(vm.query) : ActionMenuSearchQuery("")
        var rows: [PluginRow] = []
        for (sectionIndex, section) in list.sections.enumerated() {
            var first = true
            for (index, item) in section.items.enumerated() where Self.matches(item, query) {
                let id = item.id.isEmpty ? "\(sectionIndex).\(index).\(item.title)" : item.id
                rows.append(
                    PluginRow(id: id, item: item, sectionTitle: section.title, startsSection: first))
                first = false
            }
        }
        return rows
    }

    private static func matches(_ item: PluginItem, _ query: ActionMenuSearchQuery) -> Bool {
        guard !query.isEmpty else { return true }
        return ([item.title, item.subtitle ?? ""] + item.keywords).contains { query.score($0) != nil }
    }

    /// The search field's prompt while this screen shows.
    var searchPrompt: String? { list?.searchPrompt ?? list?.title }

    /// A page of Markdown has nothing to type into.
    var hidesSearchField: Bool { detailPage != nil }

    var actsWithoutRows: Bool { detailPage != nil }

    func actions(forRowAt selection: Int) -> [PluginAction] {
        if let detailPage { return detailPage.actions }
        let rows = rows
        guard rows.indices.contains(selection) else { return [] }
        return rows[selection].item.actions
    }

    var primaryActionTitle: String {
        actions(forRowAt: vm.selection).first?.title ?? String(localized: "Run")
    }

    func hasPrimaryAction(at selection: Int) -> Bool { !actions(forRowAt: selection).isEmpty }

    func hasActions(at selection: Int) -> Bool { actions(forRowAt: selection).count > 1 }

    func activate(at selection: Int) {
        guard let action = actions(forRowAt: selection).first else { return }
        plugins.perform(action)
    }

    func secondary(at selection: Int) -> Bool {
        let actions = actions(forRowAt: selection)
        guard actions.count > 1 else { return false }
        plugins.perform(actions[1])
        return true
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        let actions = actions(forRowAt: selection)
        guard !actions.isEmpty else { return nil }
        let plugins = plugins
        let header = detailPage?.title ?? (rows.indices.contains(selection) ? rows[selection].item.title : nil)
        return PopoverMenuContent(
            header: header,
            items: actions.enumerated().map { index, action in
                PopoverMenuItem(
                    title: action.title, systemImage: action.systemImage ?? Self.symbol(for: action.kind),
                    shortcut: Self.shortcut(for: action, at: index), isDestructive: action.isDestructive,
                    action: { plugins.perform(action) })
            })
    }

    /// Matched before the palette's own handling; true when an action fired.
    func dispatchShortcut(key: KeyEquivalent, modifiers: EventModifiers, at selection: Int) -> Bool {
        guard
            let action = actions(forRowAt: selection).first(where: {
                PluginShortcut(action: $0)?.matches(key: key, modifiers: modifiers) == true
            })
        else { return false }
        plugins.perform(action)
        return true
    }

    private static func symbol(for kind: PluginActionKind) -> String {
        switch kind {
        case .perform: "bolt"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .open: "arrow.up.forward.app"
        }
    }

    /// ↵ and ⌘↵ belong to the first two actions; the rest show the shortcut they declare.
    private static func shortcut(for action: PluginAction, at index: Int) -> String? {
        switch index {
        case 0: "↵"
        case 1: "⌘↵"
        default: PluginShortcut(action: action)?.glyphs
        }
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(
            PluginCommandView(
                plugins: plugins, rows: rows, selection: selection, scroll: scroll,
                onSelect: { vm.selection = $0 },
                onActivate: { activate(at: $0) }
            )
            .onChange(of: vm.query, initial: true) { _, query in
                guard let search = list?.search else { return }
                plugins.searchTextChanged(query, search: search)
            })
    }
}

/// An action's declared chord, in the terms the palette's key handling speaks.
struct PluginShortcut {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let glyphs: String

    init?(action: PluginAction) {
        guard let name = action.shortcutKey, !name.isEmpty else { return nil }
        let named: [String: (KeyEquivalent, String)] = [
            "return": (.return, "↵"), "delete": (.delete, "⌫"), "escape": (.escape, "⎋"),
            "tab": (.tab, "⇥"), "space": (.space, "Space"), "up": (.upArrow, "↑"),
            "down": (.downArrow, "↓"), "left": (.leftArrow, "←"), "right": (.rightArrow, "→")
        ]
        let glyph: String
        if let (key, label) = named[name] {
            self.key = key
            glyph = label
        } else if name.count == 1, let character = name.lowercased().first {
            key = KeyEquivalent(character)
            glyph = name.uppercased()
        } else {
            return nil
        }
        var modifiers: EventModifiers = []
        var prefix = ""
        for (word, flag, symbol) in [
            ("control", EventModifiers.control, "⌃"), ("option", .option, "⌥"),
            ("shift", .shift, "⇧"), ("command", .command, "⌘")
        ] where action.modifiers.contains(word) {
            modifiers.insert(flag)
            prefix += symbol
        }
        // A bare key would steal typing from the search field.
        guard !modifiers.isEmpty else { return nil }
        self.modifiers = modifiers
        glyphs = prefix + glyph
    }

    func matches(key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        key == self.key && modifiers.intersection([.command, .shift, .option, .control]) == self.modifiers
    }
}

/// An action's own shortcut, matched before the palette's bindings see it.
struct PluginShortcutKeys: ViewModifier {
    /// Resolved per press: a captured screen keeps the rows it had.
    let screen: () -> PluginCommandScreen?
    let selection: Int

    func body(content: Content) -> some View {
        content.onKeyPress(phases: .down) { press in
            guard !press.modifiers.isEmpty, let screen = screen() else { return .ignored }
            return screen.dispatchShortcut(
                key: ASCIIKeyboardLayout.keyEquivalent(fallingBackTo: press.key),
                modifiers: press.modifiers, at: selection) ? .handled : .ignored
        }
    }
}
