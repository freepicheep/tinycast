// The views a plugin's commands are built from, shaped like SwiftUI's. Run by Stir as the
// `Tinycast` module every plugin imports; the app never compiles this file.

import _TinycastHost

/// A piece of a command's screen. Write `body` the way SwiftUI does; Tinycast's own views are
/// the primitives at the bottom of every `body`.
public protocol View {
    associatedtype Body: View
    @ViewBuilder var body: Body { get }
}

/// What a primitive renders into. Underscored: a plugin builds views, never these.
public enum _Element {
    case list(PluginList, (() async -> Void)?)
    case detail(PluginDetail, (() async -> Void)?)
    case section(PluginSection)
    case item(PluginItem)
    case unavailable(String, String?)
}

public protocol _PrimitiveView: View {
    var _elements: [_Element] { get }
}

extension _PrimitiveView {
    public var body: Self { return self }
}

func _resolve<V: View>(_ view: V) -> [_Element] {
    if let primitive = view as? any _PrimitiveView { return primitive._elements }
    return _resolve(view.body)
}

/// Views a builder collected, rendered when the screen renders: a view kept by a
/// `NavigationLink` keeps its `@State` and shows each change.
public struct _ViewGroup: _PrimitiveView {
    let parts: [() -> [_Element]]

    public var _elements: [_Element] { parts.flatMap { $0() } }
}

@resultBuilder
public enum ViewBuilder {
    public static func buildExpression<V: View>(_ view: V) -> _ViewGroup {
        _ViewGroup(parts: [{ _resolve(view) }])
    }
    public static func buildBlock(_ groups: _ViewGroup...) -> _ViewGroup {
        _ViewGroup(parts: groups.flatMap { $0.parts })
    }
    public static func buildOptional(_ group: _ViewGroup?) -> _ViewGroup {
        group ?? _ViewGroup(parts: [])
    }
    public static func buildEither(first group: _ViewGroup) -> _ViewGroup { group }
    public static func buildEither(second group: _ViewGroup) -> _ViewGroup { group }
    public static func buildArray(_ groups: [_ViewGroup]) -> _ViewGroup {
        _ViewGroup(parts: groups.flatMap { $0.parts })
    }
}

public struct EmptyView: _PrimitiveView {
    public init() {}
    public var _elements: [_Element] { [] }
}

/// Views side by side in a builder, with no layout of their own.
public struct Group: _PrimitiveView {
    public let _elements: [_Element]
    public init<Content: View>(@ViewBuilder content: () -> Content) {
        _elements = _resolve(content())
    }
}

public struct ForEach: _PrimitiveView {
    public let _elements: [_Element]

    public init<Data: Sequence, Content: View>(
        _ data: Data, @ViewBuilder content: (Data.Element) -> Content
    ) {
        var elements: [_Element] = []
        for element in data { elements += _resolve(content(element)) }
        _elements = elements
    }

    /// `id` keeps SwiftUI's spelling; rows are told apart by their titles and position.
    public init<Data: Sequence, ID: Hashable, Content: View>(
        _ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: (Data.Element) -> Content
    ) {
        self.init(data, content: content)
    }
}

/// The searchable list of rows most commands show.
public struct List: _PrimitiveView {
    private var list: PluginList
    private var task: (() async -> Void)?

    public init<Content: View>(@ViewBuilder content: () -> Content) {
        list = PluginList(
            title: nil, searchPrompt: nil, search: nil, isLoading: false, emptyText: nil,
            emptySymbol: nil, sections: [])
        var loose: [PluginItem] = []
        for element in _resolve(content()) {
            switch element {
            case .item(let item):
                loose.append(item)
            case .section(let section):
                if !loose.isEmpty {
                    list.sections.append(PluginSection(title: nil, items: loose))
                    loose = []
                }
                list.sections.append(section)
            case .unavailable(let text, let symbol):
                list.emptyText = text
                list.emptySymbol = symbol
            case .list, .detail:
                break
            }
        }
        if !loose.isEmpty { list.sections.append(PluginSection(title: nil, items: loose)) }
    }

    public init<Data: Sequence, Row: View>(
        _ data: Data, @ViewBuilder rowContent: (Data.Element) -> Row
    ) {
        self.init { ForEach(data, content: rowContent) }
    }

    public var _elements: [_Element] { [.list(list, task)] }

    public func navigationTitle(_ title: String) -> List {
        var copy = self
        copy.list.title = title
        return copy
    }

    /// The plugin filters its own rows from `text`; without this, Tinycast filters them.
    public func searchable(text: Binding<String>, prompt: String? = nil) -> List {
        var copy = self
        copy.list.search = PluginSearch(text: text.wrappedValue, onChange: { text.wrappedValue = $0 })
        copy.list.searchPrompt = prompt
        return copy
    }

    public func loading(_ isLoading: Bool) -> List {
        var copy = self
        copy.list.isLoading = isLoading
        return copy
    }

    /// Runs once when the list first appears, and is cancelled when it leaves the stack.
    public func task(_ action: @escaping () async -> Void) -> List {
        var copy = self
        copy.task = action
        return copy
    }
}

public struct Section: _PrimitiveView {
    private let section: PluginSection

    public init<Content: View>(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        var items: [PluginItem] = []
        for element in _resolve(content()) {
            if case .item(let item) = element { items.append(item) }
        }
        section = PluginSection(title: title, items: items)
    }

    public var _elements: [_Element] { [.section(section)] }
}

/// One row: a title, and what the row shows and does around it.
public struct Item: _PrimitiveView {
    private var item: PluginItem
    private var tintName: String?
    private var symbol: String?

    public init(_ title: String, subtitle: String? = nil, systemImage: String? = nil) {
        item = PluginItem(
            id: "", title: title, subtitle: subtitle, icon: nil, badges: [], keywords: [],
            detail: nil, actions: [])
        symbol = systemImage
    }

    /// A row whose icon is a short string, usually one emoji.
    public init(_ title: String, subtitle: String? = nil, emoji: String) {
        self.init(title, subtitle: subtitle)
        item.icon = .text(emoji)
    }

    public var _elements: [_Element] {
        var rendered = item
        if let symbol { rendered.icon = .symbol(symbol, tintName) }
        return [.item(rendered)]
    }

    /// Keeps the selection on this row while its title changes.
    public func id(_ id: String) -> Item {
        var copy = self
        copy.item.id = id
        return copy
    }

    /// Trailing text, like SwiftUI's list badges.
    public func badge(_ text: String) -> Item {
        var copy = self
        copy.item.badges.append(text)
        return copy
    }

    public func badge(_ count: Int) -> Item { badge(String(count)) }

    /// Extra words Tinycast's search matches the row by.
    public func keywords(_ words: [String]) -> Item {
        var copy = self
        copy.item.keywords += words
        return copy
    }

    public func tint(_ color: Color) -> Item {
        var copy = self
        copy.tintName = color.name
        return copy
    }

    /// The first action runs on ↵, the second on ⌘↵; all of them are in the ⌘K menu.
    public func actions(@ActionBuilder _ content: () -> [Action]) -> Item {
        var copy = self
        copy.item.actions += content().map { $0.action }
        return copy
    }

    /// Shown beside the list while this row is selected.
    public func detail(_ content: () -> Detail) -> Item {
        var copy = self
        copy.item.detail = content().detail
        return copy
    }
}

/// A page of Markdown, or the pane beside a list.
public struct Detail: _PrimitiveView {
    fileprivate var detail: PluginDetail
    private var task: (() async -> Void)?

    public init(markdown: String) {
        detail = PluginDetail(title: nil, markdown: markdown, metadata: [], actions: [], isLoading: false)
    }

    public var _elements: [_Element] { [.detail(detail, task)] }

    public func navigationTitle(_ title: String) -> Detail {
        var copy = self
        copy.detail.title = title
        return copy
    }

    /// Label and value pairs below the text, written as `LabeledContent`.
    public func metadata(@MetadataBuilder _ content: () -> [LabeledContent]) -> Detail {
        var copy = self
        copy.detail.metadata += content().map { PluginMetadataEntry(label: $0.label, value: $0.value) }
        return copy
    }

    public func actions(@ActionBuilder _ content: () -> [Action]) -> Detail {
        var copy = self
        copy.detail.actions += content().map { $0.action }
        return copy
    }

    public func loading(_ isLoading: Bool) -> Detail {
        var copy = self
        copy.detail.isLoading = isLoading
        return copy
    }

    public func task(_ action: @escaping () async -> Void) -> Detail {
        var copy = self
        copy.task = action
        return copy
    }
}

public struct LabeledContent {
    let label: String
    let value: String

    public init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }
}

@resultBuilder
public enum MetadataBuilder {
    public static func buildExpression(_ entry: LabeledContent) -> [LabeledContent] { [entry] }
    public static func buildBlock(_ parts: [LabeledContent]...) -> [LabeledContent] {
        parts.flatMap { $0 }
    }
    public static func buildOptional(_ part: [LabeledContent]?) -> [LabeledContent] { part ?? [] }
    public static func buildEither(first part: [LabeledContent]) -> [LabeledContent] { part }
    public static func buildEither(second part: [LabeledContent]) -> [LabeledContent] { part }
    public static func buildArray(_ parts: [[LabeledContent]]) -> [LabeledContent] {
        parts.flatMap { $0 }
    }
}

/// What an empty list shows instead of rows.
public struct ContentUnavailableView: _PrimitiveView {
    private let text: String
    private let symbol: String?

    public init(_ title: String, systemImage: String? = nil) {
        text = title
        symbol = systemImage
    }

    /// The standard “No results” for a search that matched nothing.
    public static func search(text: String) -> ContentUnavailableView {
        ContentUnavailableView(
            text.isEmpty ? "No Results" : "No Results for “\(text)”", systemImage: "magnifyingglass")
    }

    public var _elements: [_Element] { [.unavailable(text, symbol)] }
}

/// A named tint for a row's symbol.
public struct Color {
    let name: String

    public static let gray = Color(name: "gray")
    public static let blue = Color(name: "blue")
    public static let cyan = Color(name: "cyan")
    public static let mint = Color(name: "mint")
    public static let green = Color(name: "green")
    public static let yellow = Color(name: "yellow")
    public static let orange = Color(name: "orange")
    public static let red = Color(name: "red")
    public static let pink = Color(name: "pink")
    public static let purple = Color(name: "purple")
    public static let indigo = Color(name: "indigo")
    public static let brown = Color(name: "brown")
}
