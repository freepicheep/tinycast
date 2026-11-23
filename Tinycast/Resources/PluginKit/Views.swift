// The views a plugin's commands are built from, shaped like SwiftUI's and rendered into the
// components Tinycast draws for Raycast extensions too.

import Foundation
import _TinycastHost

/// A piece of a command's screen. Write `body` the way SwiftUI does; Tinycast's own views are
/// the primitives at the bottom of every `body`.
public protocol View {
    associatedtype Body: View
    @ViewBuilder var body: Body { get }
}

/// What a primitive renders into. Underscored: a plugin builds views, never these.
public enum _Element {
    /// A component inside a screen: a row, a section, a field.
    case node(PluginNode)
    /// A whole screen (`List`, `Grid`, `Detail`, `Form`, `MenuBarExtra`), with its `task`.
    case screen(PluginNode, _Task?)
}

/// A screen's `task`, and the id that restarts it when it changes.
public struct _Task {
    let key: String
    let run: () async -> Void
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

/// A view's components, a nested screen's included (a `Detail` in a row's detail pane).
func _nodes<V: View>(_ view: V) -> [PluginNode] {
    _resolve(view).map { element in
        switch element {
        case .node(let node): return node
        case .screen(let node, _): return node
        }
    }
}

func _node(
    _ type: String, key: String? = nil, _ props: [String: PluginValue] = [:], children: [PluginNode] = []
) -> PluginNode {
    PluginNode(type: type, key: key, props: props, children: children)
}

/// Rows and sections take their container's names: an `Item` in a `List` is a `List.Item`.
func _retype(_ nodes: [PluginNode], container: String) -> [PluginNode] {
    nodes.map { node in
        var node = node
        switch node.type {
        case "Item":
            node.type = container + ".Item"
            if container == "Grid", node.props["content"] == nil, let icon = node.props["icon"] {
                node.props["content"] = icon
                node.props["icon"] = nil
            }
        case "Section":
            node.type = container + ".Section"
            node.children = _retype(node.children, container: container)
        case "EmptyView":
            node.type = container + ".EmptyView"
        default:
            break
        }
        return node
    }
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

    /// `id` keeps SwiftUI's spelling; give rows `.id(_:)` to keep the selection on one.
    public init<Data: Sequence, ID: Hashable, Content: View>(
        _ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: (Data.Element) -> Content
    ) {
        self.init(data, content: content)
    }
}

// MARK: - Images and colours

/// A row's or an action's icon: an SF Symbol, an emoji, a web image or a file's own icon.
public struct Image {
    var value: PluginValue

    public init(systemName: String) {
        value = .object(["source": .object(["systemImage": .string(systemName)])])
    }

    /// A short string drawn as the icon, usually one emoji.
    public init(emoji: String) {
        value = .string(emoji)
    }

    /// An `https` image, fetched and cached by Tinycast.
    public init(url: String) {
        value = .object(["source": .string(url)])
    }

    /// The icon Finder shows for the file, folder or app at `path`.
    public init(fileIcon path: String) {
        value = .object(["source": .object(["fileIcon": .string(path)])])
    }

    public func tint(_ color: Color) -> Image {
        var copy = self
        if case .object(var fields) = value {
            fields["tintColor"] = .string(color.name)
            copy.value = .object(fields)
        } else {
            copy.value = .object(["source": value, "tintColor": .string(color.name)])
        }
        return copy
    }

    /// Drawn in a circle, like an avatar.
    public func clipCircle() -> Image {
        var copy = self
        if case .object(var fields) = value {
            fields["mask"] = .string("circle")
            copy.value = .object(fields)
        }
        return copy
    }
}

/// A named colour, or any CSS colour.
public struct Color {
    let name: String

    public init(css: String) { name = css }
    init(name: String) { self.name = name }

    public static let gray = Color(name: "gray")
    public static let blue = Color(name: "raycast-blue")
    public static let cyan = Color(name: "cyan")
    public static let mint = Color(name: "mediumaquamarine")
    public static let green = Color(name: "raycast-green")
    public static let yellow = Color(name: "raycast-yellow")
    public static let orange = Color(name: "raycast-orange")
    public static let red = Color(name: "raycast-red")
    public static let pink = Color(name: "raycast-magenta")
    public static let purple = Color(name: "raycast-purple")
    public static let indigo = Color(name: "indigo")
    public static let brown = Color(name: "brown")
    public static let primary = Color(name: "raycast-primary-text")
    public static let secondary = Color(name: "raycast-secondary-text")
}

// MARK: - Lists

/// The searchable list of rows most commands show.
public struct List: _PrimitiveView {
    var props: [String: PluginValue] = [:]
    let rows: [PluginNode]
    var task: _Task?

    public init<Content: View>(@ViewBuilder content: () -> Content) {
        rows = _nodes(content())
    }

    public init<Data: Sequence, Row: View>(
        _ data: Data, @ViewBuilder rowContent: (Data.Element) -> Row
    ) {
        self.init { ForEach(data, content: rowContent) }
    }

    public var _elements: [_Element] {
        var props = props
        if props["filtering"] == nil { props["filtering"] = .bool(props["onSearchTextChange"] == nil) }
        return [.screen(_node("List", props, children: _retype(rows, container: "List")), task)]
    }

    public func navigationTitle(_ title: String) -> List { with("navigationTitle", .string(title)) }

    /// The plugin filters its own rows from `text`; without this, Tinycast filters them.
    public func searchable(text: Binding<String>, prompt: String? = nil) -> List {
        var copy = with("searchText", .string(text.wrappedValue))
        copy.props["onSearchTextChange"] = _handler { text.wrappedValue = $0.first?.text ?? "" }
        if let prompt { copy.props["searchBarPlaceholder"] = .string(prompt) }
        return copy
    }

    /// The search field's placeholder, with Tinycast still filtering the rows.
    public func searchable(prompt: String) -> List { with("searchBarPlaceholder", .string(prompt)) }

    public func loading(_ isLoading: Bool) -> List { with("isLoading", .bool(isLoading)) }

    /// Rows on the left and the selected row's `detail` beside them.
    public func showingDetail(_ isShowing: Bool = true) -> List { with("isShowingDetail", .bool(isShowing)) }

    /// The selected row's id, kept in step both ways.
    public func selection(_ id: Binding<String?>) -> List {
        var copy = self
        if let current = id.wrappedValue { copy.props["selectedItemId"] = .string(current) }
        copy.props["onSelectionChange"] = _handler { id.wrappedValue = $0.first?.text }
        return copy
    }

    /// A dropdown beside the search field, such as a category filter.
    public func searchBarAccessory(_ dropdown: Dropdown) -> List {
        with("searchBarAccessory", .node(dropdown.node(container: "List")))
    }

    /// The actions an empty list offers.
    public func actions(@ActionBuilder _ content: () -> [PluginNode]) -> List {
        with("actions", .node(_actionPanel(content())))
    }

    /// Runs once when the list first appears, and is cancelled when it leaves the stack.
    public func task(_ action: @escaping () async -> Void) -> List {
        var copy = self
        copy.task = _Task(key: "", run: action)
        return copy
    }

    /// Like `task(_:)`, and cancelled and started again whenever `id` changes.
    public func task<ID: Equatable>(id: ID, _ action: @escaping () async -> Void) -> List {
        var copy = self
        copy.task = _Task(key: "\(id)", run: action)
        return copy
    }

    func with(_ name: String, _ value: PluginValue) -> List {
        var copy = self
        copy.props[name] = value
        return copy
    }
}

/// A grid of tiles: images, colours or symbols, each with a title.
public struct Grid: _PrimitiveView {
    public enum Fit { case contain, fill }
    public enum Inset { case zero, small, medium, large }

    var props: [String: PluginValue] = [:]
    let tiles: [PluginNode]
    var task: _Task?

    /// - Parameters:
    ///   - aspectRatio: A tile's width to its height: `"1"`, `"3/2"`, `"2/3"`, `"4/3"`, `"3/4"`,
    ///     `"16/9"` or `"9/16"`.
    public init<Content: View>(
        columns: Int = 5, aspectRatio: String = "1", fit: Fit = .contain, inset: Inset? = nil,
        @ViewBuilder content: () -> Content
    ) {
        tiles = _nodes(content())
        props["columns"] = .number(Double(columns))
        props["aspectRatio"] = .string(aspectRatio)
        props["fit"] = .string(fit == .fill ? "fill" : "contain")
        if let inset {
            switch inset {
            case .zero: props["inset"] = .string("zero")
            case .small: props["inset"] = .string("small")
            case .medium: props["inset"] = .string("medium")
            case .large: props["inset"] = .string("large")
            }
        }
    }

    public var _elements: [_Element] {
        var props = props
        if props["filtering"] == nil { props["filtering"] = .bool(props["onSearchTextChange"] == nil) }
        return [.screen(_node("Grid", props, children: _retype(tiles, container: "Grid")), task)]
    }

    public func navigationTitle(_ title: String) -> Grid { with("navigationTitle", .string(title)) }

    public func searchable(text: Binding<String>, prompt: String? = nil) -> Grid {
        var copy = with("searchText", .string(text.wrappedValue))
        copy.props["onSearchTextChange"] = _handler { text.wrappedValue = $0.first?.text ?? "" }
        if let prompt { copy.props["searchBarPlaceholder"] = .string(prompt) }
        return copy
    }

    public func searchable(prompt: String) -> Grid { with("searchBarPlaceholder", .string(prompt)) }
    public func loading(_ isLoading: Bool) -> Grid { with("isLoading", .bool(isLoading)) }

    public func selection(_ id: Binding<String?>) -> Grid {
        var copy = self
        if let current = id.wrappedValue { copy.props["selectedItemId"] = .string(current) }
        copy.props["onSelectionChange"] = _handler { id.wrappedValue = $0.first?.text }
        return copy
    }

    public func searchBarAccessory(_ dropdown: Dropdown) -> Grid {
        with("searchBarAccessory", .node(dropdown.node(container: "Grid")))
    }

    public func actions(@ActionBuilder _ content: () -> [PluginNode]) -> Grid {
        with("actions", .node(_actionPanel(content())))
    }

    public func task(_ action: @escaping () async -> Void) -> Grid {
        var copy = self
        copy.task = _Task(key: "", run: action)
        return copy
    }

    public func task<ID: Equatable>(id: ID, _ action: @escaping () async -> Void) -> Grid {
        var copy = self
        copy.task = _Task(key: "\(id)", run: action)
        return copy
    }

    func with(_ name: String, _ value: PluginValue) -> Grid {
        var copy = self
        copy.props[name] = value
        return copy
    }
}

/// Rows under a heading, in a `List` or a `Grid`.
public struct Section: _PrimitiveView {
    let node: PluginNode

    public init<Content: View>(
        _ title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content
    ) {
        var props: [String: PluginValue] = [:]
        if let title { props["title"] = .string(title) }
        if let subtitle { props["subtitle"] = .string(subtitle) }
        node = _node("Section", key: title, props, children: _nodes(content()))
    }

    public var _elements: [_Element] { [.node(node)] }
}

/// One row of a `List`, or one tile of a `Grid`: a title, and what it shows and does around it.
public struct Item: _PrimitiveView {
    var props: [String: PluginValue]
    var key: String?
    var accessories: [PluginValue] = []

    public init(_ title: String, subtitle: String? = nil, systemImage: String? = nil) {
        props = ["title": .string(title)]
        if let subtitle { props["subtitle"] = .string(subtitle) }
        if let systemImage { props["icon"] = Image(systemName: systemImage).value }
    }

    /// A row whose icon is a short string, usually one emoji.
    public init(_ title: String, subtitle: String? = nil, emoji: String) {
        self.init(title, subtitle: subtitle, image: Image(emoji: emoji))
    }

    public init(_ title: String, subtitle: String? = nil, image: Image) {
        self.init(title, subtitle: subtitle)
        props["icon"] = image.value
    }

    /// A grid tile that is a swatch of `color`.
    public init(_ title: String, subtitle: String? = nil, color: Color) {
        self.init(title, subtitle: subtitle)
        props["content"] = .object(["color": .string(color.name)])
    }

    public var _elements: [_Element] {
        var props = props
        if !accessories.isEmpty { props["accessories"] = .array(accessories) }
        return [.node(_node("Item", key: key, props))]
    }

    /// Keeps the selection on this row while its title changes, and is what `selection` reports.
    public func id(_ id: String) -> Item {
        var copy = with("id", .string(id))
        copy.key = id
        return copy
    }

    /// Trailing text, like SwiftUI's list badges.
    public func badge(_ text: String) -> Item { accessory(text) }
    public func badge(_ count: Int) -> Item { accessory(String(count)) }

    /// Trailing text, an icon, or both, with a tooltip.
    public func accessory(_ text: String? = nil, image: Image? = nil, tooltip: String? = nil) -> Item {
        var fields: [String: PluginValue] = [:]
        if let text { fields["text"] = .string(text) }
        if let image { fields["icon"] = image.value }
        if let tooltip { fields["tooltip"] = .string(tooltip) }
        var copy = self
        copy.accessories.append(.object(fields))
        return copy
    }

    /// A date, drawn relative to now: "3h", "yesterday".
    public func accessory(date: Date, tooltip: String? = nil) -> Item {
        var fields: [String: PluginValue] = ["date": .date(date.timeIntervalSince1970)]
        if let tooltip { fields["tooltip"] = .string(tooltip) }
        var copy = self
        copy.accessories.append(.object(fields))
        return copy
    }

    /// A coloured tag.
    public func tag(_ text: String, color: Color? = nil) -> Item {
        var tag: [String: PluginValue] = ["value": .string(text)]
        if let color { tag["color"] = .string(color.name) }
        var copy = self
        copy.accessories.append(.object(["tag": .object(tag)]))
        return copy
    }

    /// Extra words Tinycast's search matches the row by.
    public func keywords(_ words: [String]) -> Item {
        var existing: [PluginValue] = []
        if case .array(let values) = props["keywords"] { existing = values }
        return with("keywords", .array(existing + words.map { PluginValue.string($0) }))
    }

    /// Tints the row's symbol.
    public func tint(_ color: Color) -> Item {
        guard case .object(var fields) = props["icon"] else { return self }
        fields["tintColor"] = .string(color.name)
        return with("icon", .object(fields))
    }

    /// A grid tile's picture, in place of its icon.
    public func content(_ image: Image) -> Item { with("content", image.value) }

    /// The first action runs on ↵, the second on ⌘↵; all of them are in the ⌘K menu.
    public func actions(@ActionBuilder _ content: () -> [PluginNode]) -> Item {
        with("actions", .node(_actionPanel(content())))
    }

    /// Shown beside the list while this row is selected, in a list that is `showingDetail`.
    public func detail(_ content: () -> Detail) -> Item {
        var node = content().node
        node.type = "List.Item.Detail"
        return with("detail", .node(node))
    }

    func with(_ name: String, _ value: PluginValue) -> Item {
        var copy = self
        copy.props[name] = value
        return copy
    }
}

/// What an empty list or grid shows instead of rows.
public struct ContentUnavailableView: _PrimitiveView {
    let props: [String: PluginValue]

    public init(_ title: String, systemImage: String? = nil, description: String? = nil) {
        var props: [String: PluginValue] = ["title": .string(title)]
        if let systemImage { props["icon"] = Image(systemName: systemImage).value }
        if let description { props["description"] = .string(description) }
        self.props = props
    }

    /// The standard “No results” for a search that matched nothing.
    public static func search(text: String) -> ContentUnavailableView {
        ContentUnavailableView(
            text.isEmpty ? "No Results" : "No Results for “\(text)”", systemImage: "magnifyingglass")
    }

    public var _elements: [_Element] { [.node(_node("EmptyView", props))] }
}

/// The dropdown beside a list's or grid's search field. Keep `selection` in `@AppStorage` to
/// remember the choice between launches.
public struct Dropdown {
    let tooltip: String
    let selection: Binding<String>
    let items: [PluginNode]

    public init(_ tooltip: String, selection: Binding<String>, @DropdownBuilder items: () -> [PluginNode]) {
        self.tooltip = tooltip
        self.selection = selection
        self.items = items()
    }

    func node(container: String) -> PluginNode {
        let binding = selection
        let retyped = items.map { item -> PluginNode in
            var item = item
            item.type = container + ".Dropdown." + item.type
            item.children = item.children.map { child in
                var child = child
                child.type = container + ".Dropdown." + child.type
                return child
            }
            return item
        }
        return _node(
            container + ".Dropdown", key: tooltip,
            [
                "tooltip": .string(tooltip), "value": .string(binding.wrappedValue),
                "onChange": _handler { binding.wrappedValue = $0.first?.text ?? "" }
            ], children: retyped)
    }
}

/// One choice of a `Dropdown`, a `Picker` or a `TagPicker`.
public struct Choice {
    let node: PluginNode

    public init(_ title: String, value: String, systemImage: String? = nil) {
        var props: [String: PluginValue] = ["title": .string(title), "value": .string(value)]
        if let systemImage { props["icon"] = Image(systemName: systemImage).value }
        node = _node("Item", key: value, props)
    }
}

/// Choices under a heading.
public struct ChoiceSection {
    let node: PluginNode

    public init(_ title: String? = nil, @DropdownBuilder _ choices: () -> [PluginNode]) {
        var props: [String: PluginValue] = [:]
        if let title { props["title"] = .string(title) }
        node = _node("Section", key: title, props, children: choices())
    }
}

@resultBuilder
public enum DropdownBuilder {
    public static func buildExpression(_ choice: Choice) -> [PluginNode] { [choice.node] }
    public static func buildExpression(_ section: ChoiceSection) -> [PluginNode] { [section.node] }
    public static func buildBlock(_ parts: [PluginNode]...) -> [PluginNode] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [PluginNode]?) -> [PluginNode] { part ?? [] }
    public static func buildEither(first part: [PluginNode]) -> [PluginNode] { part }
    public static func buildEither(second part: [PluginNode]) -> [PluginNode] { part }
    public static func buildArray(_ parts: [[PluginNode]]) -> [PluginNode] { parts.flatMap { $0 } }
}

// MARK: - Detail

/// A page of Markdown, or the pane beside a list.
public struct Detail: _PrimitiveView {
    var node: PluginNode
    var task: _Task?

    public init(markdown: String) {
        node = _node("Detail", ["markdown": .string(markdown)])
    }

    public var _elements: [_Element] { [.screen(node, task)] }

    public func navigationTitle(_ title: String) -> Detail { with("navigationTitle", .string(title)) }

    /// Labels, links and tags beside the text: a sidebar on a screen, below it in a list's pane.
    public func metadata(@MetadataBuilder _ content: () -> [PluginNode]) -> Detail {
        with("metadata", .node(_node("Detail.Metadata", children: content())))
    }

    public func actions(@ActionBuilder _ content: () -> [PluginNode]) -> Detail {
        with("actions", .node(_actionPanel(content())))
    }

    public func loading(_ isLoading: Bool) -> Detail { with("isLoading", .bool(isLoading)) }

    public func task(_ action: @escaping () async -> Void) -> Detail {
        var copy = self
        copy.task = _Task(key: "", run: action)
        return copy
    }

    public func task<ID: Equatable>(id: ID, _ action: @escaping () async -> Void) -> Detail {
        var copy = self
        copy.task = _Task(key: "\(id)", run: action)
        return copy
    }

    func with(_ name: String, _ value: PluginValue) -> Detail {
        var copy = self
        copy.node.props[name] = value
        return copy
    }
}

/// A label and its value in a `Detail`'s metadata.
public struct LabeledContent {
    let node: PluginNode

    public init(_ label: String, value: String, systemImage: String? = nil) {
        var props: [String: PluginValue] = ["title": .string(label), "text": .string(value)]
        if let systemImage { props["icon"] = Image(systemName: systemImage).value }
        node = _node("Detail.Metadata.Label", key: label, props)
    }

    public init(_ label: String, value: String, image: Image) {
        node = _node(
            "Detail.Metadata.Label", key: label,
            ["title": .string(label), "text": .string(value), "icon": image.value])
    }
}

/// A link in a `Detail`'s metadata: `text` opens `destination`.
public struct MetadataLink {
    let node: PluginNode

    public init(_ label: String, text: String, destination: String) {
        node = _node(
            "Detail.Metadata.Link", key: label,
            ["title": .string(label), "text": .string(text), "target": .string(destination)])
    }
}

/// Coloured tags under a label in a `Detail`'s metadata.
public struct TagList {
    let node: PluginNode

    public init(_ label: String, @TagBuilder tags: () -> [PluginNode]) {
        node = _node("Detail.Metadata.TagList", key: label, ["title": .string(label)], children: tags())
    }
}

public struct Tag {
    let node: PluginNode

    public init(_ text: String, color: Color? = nil) {
        var props: [String: PluginValue] = ["text": .string(text)]
        if let color { props["color"] = .string(color.name) }
        node = _node("Detail.Metadata.TagList.Item", key: text, props)
    }
}

/// A line between rows of metadata, fields of a form or items of a menu.
public struct Divider: _PrimitiveView {
    public init() {}
    public var _elements: [_Element] { [.node(_node("Separator"))] }
}

@resultBuilder
public enum MetadataBuilder {
    public static func buildExpression(_ entry: LabeledContent) -> [PluginNode] { [entry.node] }
    public static func buildExpression(_ entry: MetadataLink) -> [PluginNode] { [entry.node] }
    public static func buildExpression(_ entry: TagList) -> [PluginNode] { [entry.node] }
    public static func buildExpression(_ entry: Divider) -> [PluginNode] {
        [_node("Detail.Metadata.Separator")]
    }
    public static func buildBlock(_ parts: [PluginNode]...) -> [PluginNode] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [PluginNode]?) -> [PluginNode] { part ?? [] }
    public static func buildEither(first part: [PluginNode]) -> [PluginNode] { part }
    public static func buildEither(second part: [PluginNode]) -> [PluginNode] { part }
    public static func buildArray(_ parts: [[PluginNode]]) -> [PluginNode] { parts.flatMap { $0 } }
}

@resultBuilder
public enum TagBuilder {
    public static func buildExpression(_ tag: Tag) -> [PluginNode] { [tag.node] }
    public static func buildBlock(_ parts: [PluginNode]...) -> [PluginNode] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [PluginNode]?) -> [PluginNode] { part ?? [] }
    public static func buildEither(first part: [PluginNode]) -> [PluginNode] { part }
    public static func buildEither(second part: [PluginNode]) -> [PluginNode] { part }
    public static func buildArray(_ parts: [[PluginNode]]) -> [PluginNode] { parts.flatMap { $0 } }
}

// MARK: - Handlers

/// A closure as a handler prop: the palette calls it with its arguments.
func _handler(_ body: @escaping ([PluginValue]) -> Void) -> PluginValue {
    .handler { arguments in body(arguments) }
}

extension PluginValue {
    /// A handler's argument as text; a number or a flag prints as itself.
    var text: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }
}
