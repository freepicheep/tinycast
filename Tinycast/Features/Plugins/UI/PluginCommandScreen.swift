import SwiftUI

/// A running plugin command as a palette screen: `layout` decides the rows, so `selection` maps
/// 1:1 onto what is drawn.
struct PluginCommandScreen: PaletteScreen {
    let layout: PluginScreenLayout
    let host: PluginHost
    let vm: PaletteState
    let openActions: () -> Void

    var rows: [PluginScreenLayout.Item] { layout.items }

    /// A form's fields are the text, so the search field steps aside.
    var hidesSearchField: Bool { layout.isForm }

    var landingSelection: Int {
        if layout.isForm { return layout.autoFocusIndex }
        return vm.query.isEmpty ? layout.requestedSelection ?? 0 : 0
    }

    var actsWithoutRows: Bool { layout.isForm || layout.isDetail || layout.emptyState != nil }

    var primaryActionTitle: String {
        layout.primaryAction(at: vm.selection)?.title ?? String(localized: "Open")
    }

    func hasPrimaryAction(at selection: Int) -> Bool {
        layout.primaryAction(at: selection) != nil
    }

    func hasActions(at selection: Int) -> Bool {
        let (row, screen) = layout.actions(at: selection)
        return !(row.isEmpty && screen.isEmpty)
    }

    /// A text editor moves its caret with ↑/↓, so only ⇥ leaves it.
    func ownsVerticalKeys(at selection: Int) -> Bool {
        guard rows.indices.contains(selection), case .textEditor? = rows[selection].field?.kind else { return false }
        return true
    }

    /// ⇥ walks a form's fields, wrapping at either end.
    func tabTarget(from selection: Int, backwards: Bool) -> Int? {
        guard layout.isForm, !rows.isEmpty else { return nil }
        return (selection + (backwards ? -1 : 1) + rows.count) % rows.count
    }

    func move(_ delta: Int, axis: PaletteAxis, from selection: Int) -> Int? {
        guard let grid = layout.grid, !rows.isEmpty else { return nil }
        switch axis {
        case .vertical: return layout.gridMove(delta, from: selection, columns: grid.columns)
        case .horizontal: return min(max(selection + delta, 0), rows.count - 1)
        }
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        let (row, screen) = layout.actions(at: selection)
        var items: [PopoverMenuItem] = []
        add(row, to: &items, sectionTitle: nil)
        let rowCount = items.count
        add(screen, to: &items, sectionTitle: nil)
        if rowCount > 0, items.count > rowCount { items[rowCount].startsSection = true }
        return items.isEmpty ? nil : PopoverMenuContent(header: layout.chrome?.title, items: items)
    }

    /// Sections and menus fold into titled runs, since the palette's menu has one level.
    private func add(_ actions: [PluginAction], to items: inout [PopoverMenuItem], sectionTitle: String?) {
        var pendingTitle = sectionTitle
        var startsSection = sectionTitle != nil
        for action in actions {
            if action.isContainer {
                add(action.children, to: &items, sectionTitle: action.title.isEmpty ? nil : action.title)
                startsSection = true
                continue
            }
            let host = host
            items.append(
                PopoverMenuItem(
                    title: action.title, icon: action.icon.map(Self.menuIcon) ?? .blank,
                    sectionTitle: pendingTitle, startsSection: startsSection && !items.isEmpty,
                    shortcut: action.shortcut.map(PluginShortcuts.display),
                    isDestructive: action.role == .destructive,
                    action: { host.perform(action) }))
            pendingTitle = nil
            startsSection = false
        }
    }

    static func menuIcon(_ image: PluginImage) -> PopoverMenuIcon {
        switch image {
        case .symbol(let name, _): .symbol(name)
        case .file(let path), .fileIcon(let path): .file(path: PluginEffects.fileURL(path).path)
        case .asset(let name): .asset(name)
        default: .blank
        }
    }

    func activate(at selection: Int) {
        guard let primary = layout.primaryAction(at: selection) else { return }
        if primary.isContainer {
            vm.selection = selection
            openActions()
            return
        }
        host.perform(primary)
    }

    /// ⌘↵ runs the second action, as the footer's group lists it.
    func secondary(at selection: Int) -> Bool {
        let (row, screen) = layout.actions(at: selection)
        let all = (row + screen).flatMap(\.flattened)
        guard all.count > 1 else { return false }
        host.perform(all[1])
        return true
    }

    /// An action's own shortcut, matched before the palette's bindings see it.
    func dispatchShortcut(key: KeyEquivalent, modifiers: EventModifiers, at selection: Int) -> Bool {
        let (row, screen) = layout.actions(at: selection)
        let wanted = modifiers.intersection([.command, .shift, .option, .control])
        let match = (row + screen).flatMap(\.flattened).first { action in
            guard let shortcut = action.shortcut else { return false }
            return PluginShortcuts.keyEquivalent(shortcut.key) == key
                && PluginShortcuts.modifiers(shortcut.modifiers) == wanted
        }
        guard let match else { return false }
        host.perform(match)
        return true
    }

    // MARK: - The toolbar picker

    /// The first picker in the toolbar, drawn beside the search field.
    var toolbarPicker: PluginPicker? {
        guard let picker = layout.chrome?.pickers.first, !picker.options.isEmpty else { return nil }
        return picker
    }

    func toolbarPickerButton(_ picker: PluginPicker, isOpen: Bool, action: @escaping () -> Void) -> AnyView {
        AnyView(PluginToolbarPickerButton(picker: picker, isOpen: isOpen, action: action))
    }

    /// Its options as a palette menu, so the arrows, ↵, Escape and the click-away come free.
    func toolbarPickerMenu(
        searchQuery: ActionMenuSearchQuery, menuSelection: Binding<Int>, onActivate: @escaping (Int) -> Void
    ) -> PaletteMenuContent? {
        guard let picker = toolbarPicker else { return nil }
        var items: [PopoverMenuItem] = []
        var bestMatch: (index: Int, score: Int)?
        var lastSection: String?
        let host = host
        for (index, option) in picker.options.enumerated() {
            guard let score = searchQuery.score(option.title) else { continue }
            let section = option.section
            items.append(
                PopoverMenuItem(
                    title: option.title, icon: option.icon.map(Self.menuIcon) ?? .blank,
                    sectionTitle: section != lastSection ? section : nil,
                    startsSection: section != lastSection && !items.isEmpty,
                    detail: picker.selection == index ? "✓" : nil,
                    action: { host.set(picker.id, .index(index)) }))
            lastSection = section
            if score > (bestMatch?.score ?? .min) { bestMatch = (items.count - 1, score) }
        }
        return PaletteMenuContent(
            popover: PopoverMenuContent(header: picker.title, items: items), selection: menuSelection,
            width: PluginToolbarPickerButton.listWidth,
            search: PopoverMenu.Search(placeholder: String(localized: "Search…"), placement: .top),
            onActivate: onActivate, preferredSelection: bestMatch?.index ?? picker.selection)
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(
            PluginCommandView(
                layout: layout, state: host.state, selection: selection, scroll: scroll,
                onSelect: { vm.selection = $0 },
                onActivate: { activate(at: $0) },
                onActions: { index in
                    vm.selection = index
                    openActions()
                },
                onSet: { host.set($0, $1) },
                onSubmit: { activate(at: vm.selection) }))
    }
}
