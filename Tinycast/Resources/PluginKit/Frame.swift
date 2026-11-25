// The screen on top of the stack as the frame Tinycast draws, and the events that come back from it.
// A frame names closures by number and bindings by node id; the numbers belong to its generation.

import Foundation
import _TinycastHost

/// One frame's closures: the handlers its actions name, and the bindings its fields name.
final class _Table {
    let generation: Int
    var handlers: [Int: () -> Void] = [:]
    var bindings: [String: (PluginFieldValue) -> Void] = [:]

    init(generation: Int) {
        self.generation = generation
    }
}

/// Frames whose actions still run: the host may send one from a frame it drew just before the
/// newest reached it. An older generation's action is dropped.
let _keptGenerations = 8
var _generation = 0
var _tables: [_Table] = []

func _tinycastFrame() -> PluginFrame? {
    guard let entry = _stack.last else { return nil }
    let parts = entry.render()
    var screen = _Screen(.list, content: parts)
    for part in parts {
        if let found = part.screen {
            screen = found
            break
        }
    }
    _start(screen.task, in: entry)
    _generation += 1
    let lowering = _Lowering(_Table(generation: _generation))
    let lowered = lowering.screen(screen)
    _tables.append(lowering.table)
    if _tables.count > _keptGenerations { _tables.removeFirst(_tables.count - _keptGenerations) }
    return PluginFrame(
        version: PluginProtocolVersion.current, generation: _generation, depth: _stack.count, screen: lowered)
}

/// False when the handler's generation is too old, or names no handler.
func _tinycastPerform(_ handler: Int, _ generation: Int) -> Bool {
    for table in _tables.reversed() where table.generation == generation {
        guard let run = table.handlers[handler] else { return false }
        run()
        return true
    }
    return false
}

/// A binding by node id, as the newest frame has it: an id names the same field in every frame.
func _tinycastSet(_ node: String, _ value: PluginFieldValue) -> Bool {
    guard let set = _tables.last?.bindings[node] else { return false }
    set(value)
    return true
}

func _plain(_ text: PluginText?) -> String? {
    guard let text, case .plain(let plain) = text.content else { return nil }
    return plain
}

/// An effect as the plugin's own call, where the contract has no room for one: a menu-bar item.
func _effectRun(_ part: _Part) -> (() -> Void)? {
    let run = part.run
    var effect: (() -> Void)? = nil
    switch part.effect {
    case .openURL(let url, let application)?: effect = { open(url, application: application) }
    case .copy(let text, let concealed)?: effect = { Clipboard.copy(text, concealed: concealed) }
    case .paste(let text)?: effect = { Clipboard.paste(text) }
    case .revealInFinder(let path)?: effect = { showInFinder(path) }
    case .openWith(let path)?: effect = { _environment?.openWith(path) }
    case .trash(let paths)?: effect = { _environment?.trash(paths) }
    default: break
    }
    guard let perform = effect else { return run }
    return {
        perform()
        run?()
    }
}

/// Parts to the contract's values, registering each closure in the frame's table.
final class _Lowering {
    let table: _Table
    private var nextHandler = 1

    init(_ table: _Table) {
        self.table = table
    }

    func handler(_ run: (() -> Void)?) -> Int? {
        guard let run else { return nil }
        let id = nextHandler
        nextHandler += 1
        table.handlers[id] = run
        return id
    }

    /// `base`, or `base#2`, `base#3`… when a sibling already has it.
    func unique(_ base: String, _ used: inout Set<String>) -> String {
        var id = base
        var count = 2
        while used.contains(id) {
            id = "\(base)#\(count)"
            count += 1
        }
        used.insert(id)
        return id
    }

    func screen(_ screen: _Screen) -> PluginScreen {
        switch screen.kind {
        case .list: return .list(list(screen))
        case .grid: return .grid(grid(screen))
        case .detail: return .detail(detail(screen))
        case .form: return .form(form(screen))
        case .menuBar: return .menuBar(menuBar(screen))
        }
    }

    // MARK: Chrome

    func chrome(_ screen: _Screen, searchable: Bool) -> PluginChrome {
        var search: PluginSearchField? = nil
        if let binding = screen.search {
            search = PluginSearchField(text: binding.wrappedValue, prompt: screen.searchPrompt, binding: "search")
            table.bindings["search"] = { value in
                if case .text(let text) = value { binding.wrappedValue = text }
            }
        } else if searchable {
            search = PluginSearchField(text: "", prompt: screen.searchPrompt, binding: nil)
        }
        var pickers: [PluginPicker] = []
        var used: Set<String> = []
        var actionParts: [_Part] = []
        for part in screen.toolbar {
            if let picker = part.picker {
                pickers.append(self.picker(picker, id: unique("picker." + (part.id ?? part.title), &used)))
            } else {
                actionParts.append(part)
            }
        }
        var actions = self.actions(actionParts)
        if let refresh = screen.refresh {
            actions.append(
                PluginAction(
                    id: "refresh", title: "Refresh", icon: .symbol("arrow.clockwise", color: nil),
                    shortcut: PluginShortcut(key: .character("r"), modifiers: [.command]), role: nil, effect: nil,
                    handler: handler { Task { await refresh() } }, children: []))
        }
        return PluginChrome(
            title: screen.title, search: search, pickers: pickers, actions: actions, isLoading: screen.isLoading)
    }

    func picker(_ picker: _Picker, id: String) -> PluginPicker {
        let set = picker.set
        table.bindings[id] = { value in
            if case .index(let index) = value { set(index) }
        }
        return PluginPicker(id: id, title: picker.title, options: picker.options, selection: picker.selection)
    }

    // MARK: Actions

    /// A `Divider` splits actions into untitled sections; a `Section` or a `Menu` nests them.
    func actions(_ parts: [_Part]) -> [PluginAction] {
        var used: Set<String> = []
        if parts.contains(where: { $0.kind == .divider }) {
            var groups: [[_Part]] = [[]]
            for part in parts {
                if part.kind == .divider {
                    groups.append([])
                } else {
                    groups[groups.count - 1].append(part)
                }
            }
            var sections: [PluginAction] = []
            for group in groups where !group.isEmpty {
                sections.append(
                    PluginAction(
                        id: unique("section", &used), title: "", icon: nil, shortcut: nil, role: nil, effect: .section,
                        handler: nil, children: actions(group)))
            }
            return sections
        }
        var result: [PluginAction] = []
        for part in parts {
            switch part.kind {
            case .button:
                result.append(
                    PluginAction(
                        id: unique(part.id ?? part.title, &used), title: part.title, icon: part.icon,
                        shortcut: part.shortcut, role: part.role, effect: part.effect, handler: handler(part.run),
                        children: []))
            case .menu, .section:
                result.append(
                    PluginAction(
                        id: unique(part.id ?? part.title, &used), title: part.title, icon: part.icon,
                        shortcut: part.shortcut, role: nil, effect: part.kind == .menu ? .menu : .section,
                        handler: nil, children: actions(part.children)))
            default:
                break
            }
        }
        return result
    }

    // MARK: Lists and grids

    func list(_ screen: _Screen) -> PluginListScreen {
        let chrome = self.chrome(screen, searchable: true)
        let (sections, empty, values) = self.sections(screen, isGrid: false)
        let (selection, binding) = self.selection(screen, values)
        return PluginListScreen(
            chrome: chrome, sections: sections, emptyState: empty, showsDetail: screen.showsDetail,
            selection: selection, selectionBinding: binding)
    }

    func grid(_ screen: _Screen) -> PluginGridScreen {
        let chrome = self.chrome(screen, searchable: true)
        let (sections, empty, values) = self.sections(screen, isGrid: true)
        let (selection, binding) = self.selection(screen, values)
        return PluginGridScreen(
            chrome: chrome, sections: sections, emptyState: empty, columns: screen.columns,
            aspectRatio: screen.aspectRatio, fit: screen.fit, inset: screen.inset, selection: selection,
            selectionBinding: binding)
    }

    func selection(_ screen: _Screen, _ values: [String: AnyHashable]) -> (String?, String?) {
        guard let current = screen.selection, let select = screen.select else { return (nil, nil) }
        let value = current()
        var selected: String? = nil
        for (id, tag) in values where tag == value {
            if selected == nil || id < selected! { selected = id }
        }
        table.bindings["selection"] = { change in
            guard case .text(let id) = change else { return }
            select(values[id])
        }
        return (selected, "selection")
    }

    /// Loose rows form untitled sections between titled ones; the row ids are unique in the screen.
    func sections(
        _ screen: _Screen, isGrid: Bool
    ) -> ([PluginSection], PluginEmptyState?, [String: AnyHashable]) {
        var sections: [PluginSection] = []
        var loose: [PluginRow] = []
        var empty: PluginEmptyState? = nil
        var sectionIDs: Set<String> = []
        var rowIDs: Set<String> = []
        var values: [String: AnyHashable] = [:]
        func flush() {
            guard !loose.isEmpty else { return }
            sections.append(PluginSection(id: unique("rows", &sectionIDs), title: nil, subtitle: nil, rows: loose))
            loose = []
        }
        for (index, part) in screen.content.enumerated() {
            switch part.kind {
            case .section:
                flush()
                let sectionID = unique(part.id ?? "section", &sectionIDs)
                var rows: [PluginRow] = []
                for (position, child) in part.children.enumerated() {
                    if let row = row(child, position: "\(sectionID).\(position)", screen, isGrid, &rowIDs, &values) {
                        rows.append(row)
                    }
                }
                sections.append(
                    PluginSection(
                        id: sectionID, title: part.title.isEmpty ? nil : part.title, subtitle: _plain(part.subtitle),
                        rows: rows))
            case .empty:
                empty = emptyState(part)
            default:
                if let row = row(part, position: "\(index)", screen, isGrid, &rowIDs, &values) { loose.append(row) }
            }
        }
        flush()
        for part in screen.overlay where part.kind == .empty { empty = emptyState(part) }
        return (sections, empty, values)
    }

    func row(
        _ part: _Part, position: String, _ screen: _Screen, _ isGrid: Bool, _ used: inout Set<String>,
        _ values: inout [String: AnyHashable]
    ) -> PluginRow? {
        var source = part
        switch part.kind {
        case .row, .text:
            break
        case .button, .menu:
            // A button in a list is a row that runs it.
            var action = part
            action.actions = []
            source.actions = [action] + part.actions
        case .labeled:
            let value = part.children.first.map { $0.plainTitle } ?? ""
            source.accessories = [.text(Text(value).value)] + part.accessories
        default:
            return nil
        }
        let id = unique(part.id ?? position, &used)
        if let tag = part.tag { values[id] = tag }
        var icon = source.icon
        var content = source.content
        if isGrid, content == nil {
            content = icon
            icon = nil
        }
        return PluginRow(
            id: id, title: source.text ?? Text(source.title).value, subtitle: source.subtitle, icon: icon,
            content: content, accessories: source.accessories, keywords: source.keywords,
            actions: actions(source.actions), detail: source.detail.map { detail($0) },
            isRedacted: source.isRedacted || screen.isRedacted)
    }

    func emptyState(_ part: _Part) -> PluginEmptyState {
        PluginEmptyState(title: part.title, description: part.detailText, icon: part.icon, actions: actions(part.actions))
    }

    // MARK: Detail

    func detail(_ screen: _Screen) -> PluginDetailScreen {
        PluginDetailScreen(
            chrome: chrome(screen, searchable: false), markdown: screen.markdown, metadata: metadata(screen.metadata))
    }

    func metadata(_ parts: [_Part]) -> [PluginMetadataItem] {
        var items: [PluginMetadataItem] = []
        for part in parts {
            switch part.kind {
            case .labeled:
                let value = part.children.first
                if let value, case .openURL(let url, _)? = value.effect {
                    items.append(.link(part.title, text: value.title, url: url))
                } else {
                    items.append(
                        .label(part.title, text: value?.text ?? Text(value?.title ?? "").value, icon: value?.icon))
                }
            case .tagList:
                var tags: [PluginTag] = []
                for child in part.children where child.kind == .tag {
                    tags.append(PluginTag(text: child.title, color: child.color))
                }
                items.append(.tags(part.title, tags))
            case .divider:
                items.append(.separator)
            default:
                break
            }
        }
        return items
    }

    // MARK: Forms

    func form(_ screen: _Screen) -> PluginFormScreen {
        var used: Set<String> = []
        var fields: [PluginField] = []
        func field(_ part: _Part, id: String?, title: String?, kind: PluginFieldKind) {
            fields.append(
                PluginField(
                    id: unique(id ?? "field", &used), title: title, info: part.tooltip, error: part.error,
                    autoFocus: part.focusedByDefault, kind: kind))
        }
        func add(_ parts: [_Part]) {
            for part in parts {
                let title = part.title.isEmpty ? nil : part.title
                switch part.kind {
                case .field:
                    guard let made = part.field else { continue }
                    field(part, id: part.id ?? title, title: title, kind: made.kind)
                    table.bindings[fields[fields.count - 1].id] = made.set
                case .picker:
                    guard let made = part.picker else { continue }
                    let id = unique(part.id ?? part.title, &used)
                    fields.append(
                        PluginField(
                            id: id, title: title, info: part.tooltip, error: part.error,
                            autoFocus: part.focusedByDefault, kind: .picker(picker(made, id: id))))
                case .text, .row:
                    field(part, id: part.id, title: nil, kind: .text(part.plainTitle))
                case .labeled:
                    field(part, id: part.id, title: title, kind: .text(part.children.first?.plainTitle ?? ""))
                case .divider:
                    field(part, id: nil, title: nil, kind: .separator)
                case .section:
                    if !fields.isEmpty { field(part, id: nil, title: nil, kind: .separator) }
                    add(part.children)
                default:
                    break
                }
            }
        }
        add(screen.content)
        return PluginFormScreen(chrome: chrome(screen, searchable: false), fields: fields)
    }

    // MARK: Menu bar

    func menuBar(_ screen: _Screen) -> PluginMenuBarScreen {
        PluginMenuBarScreen(
            title: screen.title, icon: screen.icon, tooltip: screen.tooltip, isLoading: screen.isLoading,
            items: menuItems(screen.content))
    }

    func menuItems(_ parts: [_Part]) -> [PluginMenuItem] {
        var used: Set<String> = []
        var items: [PluginMenuItem] = []
        for part in parts {
            var kind = PluginMenuItemKind.item
            var children: [PluginMenuItem] = []
            var run: (() -> Void)? = nil
            switch part.kind {
            case .button:
                run = _effectRun(part)
            case .row, .text:
                if let first = part.actions.first { run = _effectRun(first) }
            case .menu:
                kind = .submenu
                children = menuItems(part.children)
            case .section:
                kind = .section
                children = menuItems(part.children)
            case .divider:
                kind = .separator
            default:
                continue
            }
            var alternate: PluginMenuAlternate? = nil
            if let other = part.alternate.first {
                alternate = PluginMenuAlternate(
                    title: other.plainTitle, subtitle: _plain(other.subtitle), icon: other.icon,
                    handler: handler(_effectRun(other)))
            }
            items.append(
                PluginMenuItem(
                    id: unique(part.id ?? (part.title.isEmpty ? "item" : part.title), &used), kind: kind,
                    title: part.plainTitle, subtitle: _plain(part.subtitle), icon: part.icon, tooltip: part.tooltip,
                    shortcut: part.shortcut, handler: handler(run), alternate: alternate, children: children))
        }
        return items
    }
}
