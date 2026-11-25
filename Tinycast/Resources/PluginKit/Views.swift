// The views a plugin's commands are built from, named and shaped as SwiftUI's. Each resolves to
// parts, and the screen on top of the stack becomes the frame Tinycast draws (Frame.swift).

import Foundation
import _TinycastHost

/// A piece of a command's screen. Write `body` as in SwiftUI; Tinycast's views are the primitives
/// at the bottom of every `body`.
public protocol View {
    associatedtype Body: View
    @ViewBuilder var body: Body { get }
}

/// A view Tinycast draws itself. Underscored: a plugin builds views, never parts.
public protocol _PrimitiveView: View {
    var _parts: [_Part] { get }
}

extension _PrimitiveView {
    public var body: Self { return self }
}

func _resolve<V: View>(_ view: V) -> [_Part] {
    if let primitive = view as? any _PrimitiveView { return primitive._parts }
    return _resolve(view.body)
}

/// Parts a modifier changed, as a view.
public struct _Parts: _PrimitiveView {
    public let _parts: [_Part]
}

/// What a view resolves to: a row, a button, a field, a whole screen. A frame is made of these.
public struct _Part {
    enum Kind {
        case row, text, section, button, menu, divider, field, picker, empty, screen, labeled, tagList, tag
    }

    var kind: Kind
    var title = ""
    /// A row's or a text's title as drawn, with its style.
    var text: PluginText? = nil
    var subtitle: PluginText? = nil
    var icon: PluginImage? = nil
    var content: PluginImage? = nil
    /// `.id(_:)` or `ForEach`'s identity.
    var id: String? = nil
    /// `.tag(_:)`, or `ForEach`'s identity: what a picker or a selection sets.
    var tag: AnyHashable? = nil
    var children: [_Part] = []
    var accessories: [PluginAccessory] = []
    var keywords: [String] = []
    var actions: [_Part] = []
    var detail: _Screen? = nil
    var isRedacted = false
    var tooltip: String? = nil
    var role: PluginActionRole? = nil
    var shortcut: PluginShortcut? = nil
    var effect: PluginEffect? = nil
    var run: (() -> Void)? = nil
    var alternate: [_Part] = []
    var field: _Field? = nil
    var picker: _Picker? = nil
    var error: String? = nil
    var focusedByDefault = false
    var screen: _Screen? = nil
    var color: PluginColor? = nil
    var detailText: String? = nil

    init(_ kind: Kind) {
        self.kind = kind
    }

    /// A row's title as plain text, for search and for a picker's option.
    var plainTitle: String {
        if let text, case .plain(let plain) = text.content { return plain }
        return title
    }
}

/// One screen: a list, a grid, a detail, a form or a menu-bar item, with what's around its content.
public final class _Screen {
    enum Kind { case list, grid, detail, form, menuBar }

    let kind: Kind
    var content: [_Part]
    var title: String? = nil
    var search: Binding<String>? = nil
    var searchPrompt: String? = nil
    var toolbar: [_Part] = []
    var overlay: [_Part] = []
    var isLoading = false
    var isRedacted = false
    var showsDetail = false
    var selection: (() -> AnyHashable?)? = nil
    var select: ((AnyHashable?) -> Void)? = nil
    var task: _Task? = nil
    var refresh: (() async -> Void)? = nil
    var columns = 5
    var aspectRatio = 1.0
    var fit = PluginImageFit.contain
    var inset = PluginGridInset.none
    var markdown = ""
    var metadata: [_Part] = []
    var icon: PluginImage? = nil
    var tooltip: String? = nil

    init(_ kind: Kind, content: [_Part]) {
        self.kind = kind
        self.content = content
    }

    var part: _Part {
        var part = _Part(.screen)
        part.screen = self
        return part
    }
}

/// A screen's `task`, and the id that restarts it when it changes.
public struct _Task {
    let key: String
    let run: () async -> Void
}

/// Views a builder collected, resolved when the screen renders.
public struct _ViewGroup: _PrimitiveView {
    let parts: [() -> [_Part]]

    public var _parts: [_Part] { parts.flatMap { $0() } }
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
    public var _parts: [_Part] { [] }
}

/// Views side by side, with no layout of their own.
public struct Group: _PrimitiveView {
    public let _parts: [_Part]

    public init<Content: View>(@ViewBuilder content: () -> Content) {
        _parts = _resolve(content())
    }
}

/// A view for each element, identified as in SwiftUI: the identity keeps the selection on a row
/// as the data changes, and tags the row for a picker or a selection.
public struct ForEach: _PrimitiveView {
    public let _parts: [_Part]

    public init<Data: Sequence, ID: Hashable, Content: View>(
        _ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: (Data.Element) -> Content
    ) {
        var parts: [_Part] = []
        for element in data {
            let identity = element[keyPath: id]
            for var part in _resolve(content(element)) {
                if part.id == nil { part.id = "\(identity)" }
                if part.tag == nil { part.tag = AnyHashable(identity) }
                parts.append(part)
            }
        }
        _parts = parts
    }

    public init<Data: Sequence, Content: View>(
        _ data: Data, @ViewBuilder content: (Data.Element) -> Content
    ) where Data.Element: Identifiable {
        self.init(data, id: \.id, content: content)
    }

    public init<Content: View>(_ data: Range<Int>, @ViewBuilder content: (Int) -> Content) {
        self.init(data, id: \.self, content: content)
    }
}

// MARK: - Text, labels, images and colours

/// Styled text: a row's title, a badge, a line in a form.
public struct Text: _PrimitiveView, ExpressibleByStringLiteral {
    public enum DateStyle {
        case relative
        case offset
        case timer
        case date
        case time
    }

    var value: PluginText

    public init(_ content: String) {
        value = PluginText(content: .plain(content), color: nil, isBold: false, isMonospaced: false)
    }

    public init(stringLiteral content: String) {
        self.init(content)
    }

    /// A date the host draws in the user's locale, and keeps current: "3 hours ago", "in 5 min".
    public init(_ date: Date, style: DateStyle) {
        let wire: PluginDateStyle
        switch style {
        case .relative: wire = .relative
        case .offset: wire = .offset
        case .timer: wire = .timer
        case .date: wire = .date
        case .time: wire = .time
        }
        value = PluginText(
            content: .date(date.timeIntervalSince1970, style: wire), color: nil, isBold: false, isMonospaced: false)
    }

    public func bold(_ isActive: Bool = true) -> Text {
        var copy = self
        copy.value.isBold = isActive
        return copy
    }

    public func monospaced(_ isActive: Bool = true) -> Text {
        var copy = self
        copy.value.isMonospaced = isActive
        return copy
    }

    public func foregroundStyle(_ color: Color) -> Text {
        var copy = self
        copy.value.color = color.value
        return copy
    }

    var plain: String {
        if case .plain(let text) = value.content { return text }
        return ""
    }

    public var _parts: [_Part] {
        var part = _Part(.text)
        part.title = plain
        part.text = value
        return [part]
    }
}

/// A title with an icon: a row of a list, a tile of a grid, an option of a picker.
public struct Label: _PrimitiveView {
    let title: Text
    let icon: Image?

    public init(_ title: String, systemImage: String) {
        self.title = Text(title)
        icon = Image(systemName: systemImage)
    }

    public init(_ title: String, image: Image) {
        self.title = Text(title)
        icon = image
    }

    public init(_ title: Text, image: Image? = nil) {
        self.title = title
        icon = image
    }

    public var _parts: [_Part] {
        var part = _Part(.row)
        part.title = title.plain
        part.text = title.value
        part.icon = icon?.value
        return [part]
    }
}

public struct Circle {
    public init() {}
}

public struct RoundedRectangle {
    public init(cornerRadius: Double = 4) {}
}

/// An icon: an SF Symbol, an image in the plugin's folder, a web image, a file's own icon.
public struct Image {
    var value: PluginImage

    public init(systemName: String) {
        value = .symbol(systemName, color: nil)
    }

    /// A file in the plugin's own folder, by its name there.
    public init(_ name: String) {
        value = .asset(name)
    }

    /// An `https` image, fetched and cached by Tinycast.
    public init(url: URL) {
        value = .remote(url.absoluteString, mask: nil)
    }

    public init(contentsOfFile path: String) {
        value = .file(path)
    }

    /// The icon Finder shows for the file, folder or app at `path`.
    public init(fileIconFor path: String) {
        value = .fileIcon(path)
    }

    /// A short string drawn as the icon, usually one emoji.
    public init(emoji: String) {
        value = .emoji(emoji)
    }

    /// A swatch of `color`: a grid tile that is a colour.
    public init(color: Color) {
        value = .color(color.value)
    }

    /// Tints an SF Symbol.
    public func foregroundStyle(_ color: Color) -> Image {
        guard case .symbol(let name, _) = value else { return self }
        var copy = self
        copy.value = .symbol(name, color: color.value)
        return copy
    }

    /// A web image drawn in a circle, like an avatar.
    public func clipShape(_ shape: Circle) -> Image { masked(.circle) }
    public func clipShape(_ shape: RoundedRectangle) -> Image { masked(.roundedRectangle) }

    func masked(_ mask: PluginImageMask) -> Image {
        guard case .remote(let url, _) = value else { return self }
        var copy = self
        copy.value = .remote(url, mask: mask)
        return copy
    }
}

/// SwiftUI's named colours, which follow the appearance, or one of your own.
public struct Color {
    var value: PluginColor

    init(_ value: PluginColor) {
        self.value = value
    }

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        value = .rgba(red, green, blue, opacity)
    }

    public func opacity(_ opacity: Double) -> Color {
        guard case .rgba(let red, let green, let blue, _) = value else { return self }
        return Color(red: red, green: green, blue: blue, opacity: opacity)
    }

    public static let primary = Color(.semantic(.primary))
    public static let secondary = Color(.semantic(.secondary))
    public static let accentColor = Color(.semantic(.accent))
    public static let red = Color(.semantic(.red))
    public static let orange = Color(.semantic(.orange))
    public static let yellow = Color(.semantic(.yellow))
    public static let green = Color(.semantic(.green))
    public static let mint = Color(.semantic(.mint))
    public static let teal = Color(.semantic(.teal))
    public static let cyan = Color(.semantic(.cyan))
    public static let blue = Color(.semantic(.blue))
    public static let indigo = Color(.semantic(.indigo))
    public static let purple = Color(.semantic(.purple))
    public static let pink = Color(.semantic(.pink))
    public static let brown = Color(.semantic(.brown))
    public static let gray = Color(.semantic(.gray))
}

// MARK: - Lists and grids

/// The searchable list of rows most commands show. Without `.searchable(text:)` Tinycast filters
/// the rows by title, subtitle and `.searchKeywords`.
public struct List: _PrimitiveView {
    let screen: _Screen

    public init<Content: View>(@ViewBuilder content: () -> Content) {
        screen = _Screen(.list, content: _resolve(content()))
    }

    /// The selected row's tag (`ForEach`'s identity, or `.tag(_:)`), kept in step both ways.
    public init<SelectionValue: Hashable, Content: View>(
        selection: Binding<SelectionValue?>, @ViewBuilder content: () -> Content
    ) {
        screen = _Screen(.list, content: _resolve(content()))
        screen.selection = { selection.wrappedValue.map { AnyHashable($0) } }
        screen.select = { value in selection.wrappedValue = value?.base as? SelectionValue }
    }

    public init<Data: Sequence, Row: View>(
        _ data: Data, @ViewBuilder rowContent: (Data.Element) -> Row
    ) where Data.Element: Identifiable {
        screen = _Screen(.list, content: ForEach(data, id: \.id, content: rowContent)._parts)
    }

    public init<Data: Sequence, ID: Hashable, Row: View>(
        _ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder rowContent: (Data.Element) -> Row
    ) {
        screen = _Screen(.list, content: ForEach(data, id: id, content: rowContent)._parts)
    }

    public var _parts: [_Part] { [screen.part] }
}

/// Tiles of images, colours or symbols, each with a title.
public struct Grid: _PrimitiveView {
    public enum Inset {
        case zero
        case small
        case medium
        case large
    }

    public enum ContentMode {
        case fit
        case fill
    }

    let screen: _Screen

    /// `aspectRatio` is a tile's width over its height: `1.5` for 3:2.
    public init<Content: View>(
        columns: Int = 5, aspectRatio: Double = 1, contentMode: ContentMode = .fit, inset: Inset = .zero,
        @ViewBuilder content: () -> Content
    ) {
        screen = _Screen(.grid, content: _resolve(content()))
        screen.columns = columns
        screen.aspectRatio = aspectRatio
        screen.fit = contentMode == .fill ? .fill : .contain
        switch inset {
        case .zero: screen.inset = .none
        case .small: screen.inset = .small
        case .medium: screen.inset = .medium
        case .large: screen.inset = .large
        }
    }

    public var _parts: [_Part] { [screen.part] }
}

/// Rows under a heading, in a list, a grid, a picker, a form or a menu.
public struct Section: _PrimitiveView {
    let title: String?
    let subtitle: String?
    let content: [_Part]

    public init<Content: View>(
        _ title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = _resolve(content())
    }

    public var _parts: [_Part] {
        var part = _Part(.section)
        part.title = title ?? ""
        part.subtitle = subtitle.map { Text($0).value }
        part.id = title
        part.children = content
        return [part]
    }
}

/// What an empty list or grid shows instead of rows.
public struct ContentUnavailableView: _PrimitiveView {
    let title: String
    let icon: PluginImage?
    let description: String?

    public init(_ title: String, systemImage: String? = nil, description: Text? = nil) {
        self.title = title
        icon = systemImage.map { PluginImage.symbol($0, color: nil) }
        self.description = description?.plain
    }

    /// The standard "No Results".
    public static var search: ContentUnavailableView {
        ContentUnavailableView("No Results", systemImage: "magnifyingglass")
    }

    /// "No Results for “text”".
    public static func search(text: String) -> ContentUnavailableView {
        ContentUnavailableView(
            text.isEmpty ? "No Results" : "No Results for “\(text)”", systemImage: "magnifyingglass",
            description: "Check the spelling or try a new search.")
    }

    public var _parts: [_Part] {
        var part = _Part(.empty)
        part.title = title
        part.icon = icon
        part.detailText = description
        return [part]
    }
}

// MARK: - Detail

/// A page of Markdown, or the pane beside a list's selected row.
public struct Detail: _PrimitiveView {
    let screen: _Screen

    public init(markdown: String) {
        screen = _Screen(.detail, content: [])
        screen.markdown = markdown
    }

    /// Labels, links and tags beside the text: a sidebar on a screen, below it in a list's pane.
    public func metadata<Content: View>(@ViewBuilder _ content: () -> Content) -> Detail {
        screen.metadata = _resolve(content())
        return self
    }

    public var _parts: [_Part] { [screen.part] }
}

/// A label and its value: a line of a detail's metadata or of a form. Its content may be a
/// `Link`, which opens the destination.
public struct LabeledContent: _PrimitiveView {
    let label: String
    let value: [_Part]

    public init(_ label: String, value: String) {
        self.label = label
        self.value = Text(value)._parts
    }

    public init<Content: View>(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        value = _resolve(content())
    }

    public var _parts: [_Part] {
        var part = _Part(.labeled)
        part.title = label
        part.children = value
        return [part]
    }
}

/// Coloured tags under a label in a detail's metadata.
public struct TagList: _PrimitiveView {
    let label: String
    let tags: [_Part]

    public init<Content: View>(_ label: String, @ViewBuilder tags: () -> Content) {
        self.label = label
        self.tags = _resolve(tags())
    }

    public var _parts: [_Part] {
        var part = _Part(.tagList)
        part.title = label
        part.children = tags
        return [part]
    }
}

/// A coloured tag: in a `TagList`, or a row's `.badge`.
public struct Tag: _PrimitiveView {
    let text: String
    let color: Color?

    public init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    public var _parts: [_Part] {
        var part = _Part(.tag)
        part.title = text
        part.color = color?.value
        return [part]
    }
}

/// A line between rows of metadata, fields of a form, items of a menu, groups of actions.
public struct Divider: _PrimitiveView {
    public init() {}
    public var _parts: [_Part] { [_Part(.divider)] }
}
