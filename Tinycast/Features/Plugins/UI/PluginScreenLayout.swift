import Foundation

/// A frame as the palette walks it: the rows it lands on in visible order, which a list without a
/// search binding filters by the query here, and a form's fields that take focus.
struct PluginScreenLayout {
    struct Item: Identifiable {
        let id: String
        let index: Int
        let row: PluginRow?
        let field: PluginField?
    }

    struct Section: Identifiable {
        let id: String
        let title: String?
        let subtitle: String?
        let items: [Item]
    }

    let screen: PluginScreen?
    let sections: [Section]
    let items: [Item]

    static let empty = PluginScreenLayout(screen: nil, query: "")

    init(screen: PluginScreen?, query: String) {
        self.screen = screen
        var sections: [Section] = []
        var items: [Item] = []
        switch screen {
        case .list(let list):
            let filter = list.chrome.search?.binding == nil ? ActionMenuSearchQuery(query) : ActionMenuSearchQuery("")
            Self.collect(list.sections, filter: filter, into: &sections, items: &items)
        case .grid(let grid):
            let filter = grid.chrome.search?.binding == nil ? ActionMenuSearchQuery(query) : ActionMenuSearchQuery("")
            Self.collect(grid.sections, filter: filter, into: &sections, items: &items)
        case .form(let form):
            for field in form.fields where field.takesFocus {
                items.append(Item(id: field.id, index: items.count, row: nil, field: field))
            }
        case .detail, .menuBar, .unsupported, nil:
            break
        }
        self.sections = sections
        self.items = items
    }

    private static func collect(
        _ sections: [PluginSection], filter: ActionMenuSearchQuery, into result: inout [Section], items: inout [Item]
    ) {
        for section in sections {
            var kept: [Item] = []
            for row in section.rows where filter.isEmpty || row.matches(filter) {
                let item = Item(id: "\(section.id)/\(row.id)", index: items.count, row: row, field: nil)
                kept.append(item)
                items.append(item)
            }
            if !kept.isEmpty {
                result.append(Section(id: section.id, title: section.title, subtitle: section.subtitle, items: kept))
            }
        }
    }

    var chrome: PluginChrome? { screen?.chrome }

    var isForm: Bool {
        if case .form = screen { return true }
        return false
    }

    var isDetail: Bool {
        if case .detail = screen { return true }
        return false
    }

    var grid: PluginGridScreen? {
        if case .grid(let grid) = screen { return grid }
        return nil
    }

    var emptyState: PluginEmptyState? {
        switch screen {
        case .list(let list): list.emptyState
        case .grid(let grid): grid.emptyState
        default: nil
        }
    }

    var selectionBinding: String? {
        switch screen {
        case .list(let list): list.selectionBinding
        case .grid(let grid): grid.selectionBinding
        default: nil
        }
    }

    /// The row the plugin asked to have selected, as a palette index.
    var requestedSelection: Int? {
        let id: String? =
            switch screen {
            case .list(let list): list.selection
            case .grid(let grid): grid.selection
            default: nil
            }
        guard let id else { return nil }
        return items.first { $0.row?.id == id }?.index
    }

    /// The field a form asks to start in.
    var autoFocusIndex: Int {
        items.first { $0.field?.autoFocus == true }?.index ?? 0
    }

    /// The row's own actions, then the screen's toolbar ones; a form or detail has only the latter.
    func actions(at selection: Int) -> (row: [PluginAction], screen: [PluginAction]) {
        let screenActions = chrome?.actions ?? []
        if let row = items.indices.contains(selection) ? items[selection].row : nil {
            return (row.actions, screenActions)
        }
        if items.isEmpty, let empty = emptyState, !(chrome?.isLoading ?? false) {
            return (empty.actions, screenActions)
        }
        return ([], screenActions)
    }

    /// What ↵ runs: the first of the row's actions, else the screen's.
    func primaryAction(at selection: Int) -> PluginAction? {
        let (row, screen) = actions(at: selection)
        return row.first ?? screen.first
    }

    /// Tile rows per section, so ↑ and ↓ move by a column within a section and between them.
    func gridMove(_ delta: Int, from selection: Int, columns: Int) -> Int {
        guard columns > 0, !items.isEmpty else { return selection }
        var starts: [Int] = []
        var start = 0
        for section in sections {
            starts.append(start)
            start += section.items.count
        }
        guard let sectionIndex = starts.lastIndex(where: { $0 <= selection }) else { return selection }
        let offset = selection - starts[sectionIndex]
        let column = offset % columns
        let count = sections[sectionIndex].items.count
        if delta > 0 {
            if offset + columns < count { return selection + columns }
            let lastRowStart = (count - 1) / columns * columns
            if offset < lastRowStart { return starts[sectionIndex] + count - 1 }
            guard sectionIndex + 1 < sections.count else { return selection }
            let next = sections[sectionIndex + 1].items.count
            return starts[sectionIndex + 1] + min(column, next - 1)
        }
        if offset >= columns { return selection - columns }
        guard sectionIndex > 0 else { return selection }
        let previous = sections[sectionIndex - 1].items.count
        let lastRow = (previous - 1) / columns * columns
        return starts[sectionIndex - 1] + min(lastRow + column, previous - 1)
    }
}

extension PluginRow {
    func matches(_ query: ActionMenuSearchQuery) -> Bool {
        if query.score(title.plain) != nil { return true }
        if let subtitle, query.score(subtitle.plain) != nil { return true }
        return keywords.contains { query.score($0) != nil }
    }
}

extension PluginText {
    /// The words, for filtering and accessibility; a date as it reads today.
    var plain: String {
        switch content {
        case .plain(let text): text
        case .date(let seconds, _): Date(timeIntervalSince1970: seconds).formatted()
        case .unsupported: ""
        }
    }
}

extension PluginField {
    var takesFocus: Bool {
        switch kind {
        case .text, .separator, .unsupported: false
        default: true
        }
    }
}

extension PluginAction {
    /// What can be chosen: a section or a menu only holds others.
    var isContainer: Bool {
        switch effect {
        case .section?, .menu?: true
        default: false
        }
    }

    /// Itself and everything nested in it, in menu order.
    var flattened: [PluginAction] {
        isContainer ? children.flatMap(\.flattened) : [self]
    }
}

extension PluginScreen {
    var chrome: PluginChrome? {
        switch self {
        case .list(let list): list.chrome
        case .grid(let grid): grid.chrome
        case .detail(let detail): detail.chrome
        case .form(let form): form.chrome
        case .menuBar, .unsupported: nil
        }
    }
}
