import Foundation
import Scrift

// The contract between a plugin and the host that draws it: one frame per render, a typed tree with
// no string-keyed props and no other launcher's names. The kit builds these values directly in the
// script, the helper sends them as JSON, and the host draws them with its own views. A newer minor
// version may add enum cases: an older host decodes one as `unsupported` and draws a placeholder.

/// `major` changes break the contract; `minor` ones only add to it.
@ScriftExport
struct PluginProtocolVersion {
    var major: Int
    var minor: Int

    static let current: PluginProtocolVersion = PluginProtocolVersion(major: 1, minor: 0)
}

/// Everything the host draws for one render of a command.
@ScriftExport
struct PluginFrame {
    var version: PluginProtocolVersion
    /// Counts the command's renders; events name the generation they were sent from, and the kit
    /// drops those from an older one.
    var generation: Int
    /// Screens on the command's navigation stack; more than one means Escape goes back.
    var depth: Int
    var screen: PluginScreen
}

@ScriftExport
enum PluginScreen {
    case list(PluginListScreen)
    case grid(PluginGridScreen)
    case detail(PluginDetailScreen)
    case form(PluginFormScreen)
    case menuBar(PluginMenuBarScreen)
    case unsupported(String)
}

/// What every screen in the palette has around its content.
@ScriftExport
struct PluginChrome {
    var title: String?
    /// Nil hides the search field (a detail or a form).
    var search: PluginSearchField?
    /// Pickers beside the search field.
    var pickers: [PluginPicker]
    /// The screen's own actions: an empty list's, a detail's, a form's (the first is ⌘↵).
    var actions: [PluginAction]
    var isLoading: Bool
}

/// The search field. Without a `binding` the host filters rows itself, by title, subtitle and
/// keywords; with one the plugin gets each keystroke and filters its own rows.
@ScriftExport
struct PluginSearchField {
    var text: String
    var prompt: String?
    var binding: String?
}

/// A choice of tags, for a toolbar or a form. The selection crosses as an index into `options`,
/// which the kit maps back to the Swift value it tagged.
@ScriftExport
struct PluginPicker {
    var id: String
    var title: String
    var options: [PluginOption]
    var selection: Int?
}

@ScriftExport
struct PluginOption {
    var title: String
    var icon: PluginImage?
    /// The heading this option sits under, if its section has one.
    var section: String?
}

// MARK: - Lists and grids

@ScriftExport
struct PluginListScreen {
    var chrome: PluginChrome
    var sections: [PluginSection]
    /// Shown when no row is left, after the host's own filtering.
    var emptyState: PluginEmptyState?
    /// The selected row's `detail` beside the rows.
    var showsDetail: Bool
    /// The row the plugin selected, and where the host reports the user's selection.
    var selection: String?
    var selectionBinding: String?
}

@ScriftExport
struct PluginGridScreen {
    var chrome: PluginChrome
    var sections: [PluginSection]
    var emptyState: PluginEmptyState?
    var columns: Int
    /// A tile's width over its height.
    var aspectRatio: Double
    var fit: PluginImageFit
    var inset: PluginGridInset
    var selection: String?
    var selectionBinding: String?
}

@ScriftExport
enum PluginImageFit {
    case contain
    case fill
}

@ScriftExport
enum PluginGridInset {
    case none
    case small
    case medium
    case large
}

/// Rows under an optional heading; a list without sections is one untitled section.
@ScriftExport
struct PluginSection {
    var id: String
    var title: String?
    var subtitle: String?
    var rows: [PluginRow]
}

/// A list row or a grid tile.
@ScriftExport
struct PluginRow {
    /// From `ForEach`'s identity, or the position among siblings: the host keeps the selection and
    /// scroll position on it across frames.
    var id: String
    var title: PluginText
    var subtitle: PluginText?
    var icon: PluginImage?
    /// A grid tile's picture, in place of its icon.
    var content: PluginImage?
    var accessories: [PluginAccessory]
    var keywords: [String]
    /// `actions[0]` runs on Return, `actions[1]` on ⌘Return; ⌘K lists them all.
    var actions: [PluginAction]
    var detail: PluginDetailScreen?
    /// Drawn as a placeholder while the screen is loading.
    var isRedacted: Bool
}

/// What an empty list shows: SwiftUI's `ContentUnavailableView`.
@ScriftExport
struct PluginEmptyState {
    var title: String
    var description: String?
    var icon: PluginImage?
    var actions: [PluginAction]
}

/// Trailing content of a row.
@ScriftExport
enum PluginAccessory {
    case text(PluginText)
    case count(Int)
    case label(PluginText, icon: PluginImage)
    case icon(PluginImage, tooltip: String?)
    case tag(String, color: PluginColor?)
    case unsupported(String)
}

// MARK: - Text, images and colours

@ScriftExport
struct PluginText {
    var content: PluginTextContent
    var color: PluginColor?
    var isBold: Bool
    var isMonospaced: Bool
}

@ScriftExport
enum PluginTextContent {
    case plain(String)
    /// Seconds since 1970, drawn by the host in the user's locale.
    case date(Double, style: PluginDateStyle)
    case unsupported(String)
}

/// SwiftUI's `Text.DateStyle`.
@ScriftExport
enum PluginDateStyle {
    case relative
    case offset
    case timer
    case date
    case time
}

@ScriftExport
enum PluginImage {
    case symbol(String, color: PluginColor?)
    /// An `https` image the host fetches and caches.
    case remote(String, mask: PluginImageMask?)
    /// A file the plugin names by path.
    case file(String)
    /// The icon Finder shows for a file, folder or app.
    case fileIcon(String)
    /// A file in the plugin's own folder.
    case asset(String)
    case emoji(String)
    /// A swatch: a grid tile that is a colour.
    case color(PluginColor)
    case unsupported(String)
}

@ScriftExport
enum PluginImageMask {
    case circle
    case roundedRectangle
}

@ScriftExport
enum PluginColor {
    case semantic(PluginSemanticColor)
    case rgba(Double, Double, Double, Double)
    case unsupported(String)
}

/// SwiftUI's named colours.
@ScriftExport
enum PluginSemanticColor {
    case primary
    case secondary
    case accent
    case red
    case orange
    case yellow
    case green
    case mint
    case teal
    case cyan
    case blue
    case indigo
    case purple
    case pink
    case brown
    case gray
}

// MARK: - Actions

/// One entry of a row's or a screen's actions. Effects are data the host performs after checking
/// the plugin's grants; `handler` is the plugin's own code, run after the effect if there is one.
@ScriftExport
struct PluginAction {
    var id: String
    var title: String
    var icon: PluginImage?
    var shortcut: PluginShortcut?
    var role: PluginActionRole?
    var effect: PluginEffect?
    var handler: Int?
    /// A section or a submenu's entries, for `effect` `.section` and `.menu`.
    var children: [PluginAction]
}

@ScriftExport
enum PluginActionRole {
    case destructive
    case cancel
}

@ScriftExport
enum PluginEffect {
    /// A web address, a file path or an app link the manifest allows; the palette closes.
    case openURL(String, application: String?)
    /// Copied, the palette closes and says so; `concealed` keeps it out of clipboard history.
    case copy(String, concealed: Bool)
    case paste(String)
    case revealInFinder(String)
    case openWith(String)
    case trash([String])
    /// The next screen: the handler pushes it.
    case push
    /// A form's submit: the fields marked `storeValue` are saved first.
    case submit
    /// `children` under a heading.
    case section
    /// `children` one level down.
    case menu
    case unsupported(String)
}

@ScriftExport
struct PluginShortcut {
    var key: PluginKey
    var modifiers: [PluginModifier]
}

@ScriftExport
enum PluginKey {
    case character(String)
    case returnKey
    case delete
    case deleteForward
    case tab
    case space
    case escape
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
    case unsupported(String)
}

@ScriftExport
enum PluginModifier {
    case command
    case shift
    case option
    case control
}

// MARK: - Detail

@ScriftExport
struct PluginDetailScreen {
    var chrome: PluginChrome
    var markdown: String
    var metadata: [PluginMetadataItem]
}

@ScriftExport
enum PluginMetadataItem {
    case label(String, text: PluginText, icon: PluginImage?)
    case link(String, text: String, url: String)
    case tags(String, [PluginTag])
    case separator
    case unsupported(String)
}

@ScriftExport
struct PluginTag {
    var text: String
    var color: PluginColor?
}

// MARK: - Forms

@ScriftExport
struct PluginFormScreen {
    var chrome: PluginChrome
    var fields: [PluginField]
}

@ScriftExport
struct PluginField {
    /// Also what the field's value is saved under with `storeValue`.
    var id: String
    var title: String?
    var info: String?
    var error: String?
    var autoFocus: Bool
    var kind: PluginFieldKind
}

@ScriftExport
enum PluginFieldKind {
    case textField(String, prompt: String?, isSecure: Bool)
    case textEditor(String, prompt: String?)
    case toggle(String, isOn: Bool)
    case picker(PluginPicker)
    /// Any number of options, drawn as chips: the selected indices.
    case multiPicker([PluginOption], selection: [Int])
    /// Seconds since 1970, or nil for none.
    case datePicker(Double?, includesTime: Bool)
    case filePicker([String], allowsMultiple: Bool, choosesDirectories: Bool, choosesFiles: Bool)
    case text(String)
    case separator
    case unsupported(String)
}

/// A field's new value, typed by its kind.
@ScriftExport
enum PluginFieldValue {
    case text(String)
    case bool(Bool)
    case index(Int?)
    case indices([Int])
    case date(Double?)
    case paths([String])
}

// MARK: - Menu bar

@ScriftExport
struct PluginMenuBarScreen {
    var title: String?
    var icon: PluginImage?
    var tooltip: String?
    /// While true, the item keeps its last menu and the command keeps running.
    var isLoading: Bool
    var items: [PluginMenuItem]
}

@ScriftExport
struct PluginMenuItem {
    var id: String
    var kind: PluginMenuItemKind
    var title: String
    var subtitle: String?
    var icon: PluginImage?
    var tooltip: String?
    var shortcut: PluginShortcut?
    var handler: Int?
    /// Shown in this item's place while Option is held.
    var alternate: PluginMenuAlternate?
    /// A section's or a submenu's items.
    var children: [PluginMenuItem]
}

@ScriftExport
enum PluginMenuItemKind {
    case item
    case section
    case submenu
    case separator
    case unsupported(String)
}

@ScriftExport
struct PluginMenuAlternate {
    var title: String
    var subtitle: String?
    var icon: PluginImage?
    var handler: Int?
}

// MARK: - Events, host to plugin

/// What the host sends back. Each names the frame generation it was drawn from.
enum PluginEvent {
    /// An action's or a menu item's handler.
    case perform(Int, generation: Int)
    /// A field, picker or selection's binding, by its node id.
    case set(String, value: PluginFieldValue, generation: Int)
    /// The search field's text, for a plugin that filters itself.
    case search(String, generation: Int)
    /// Escape or the back chevron.
    case back
}

// MARK: - Conformances, which Swift synthesizes only in this file

extension PluginProtocolVersion: Codable, Equatable, Sendable {}
extension PluginFrame: Codable, Equatable, Sendable {}
extension PluginChrome: Codable, Equatable, Sendable {}
extension PluginSearchField: Codable, Equatable, Sendable {}
extension PluginPicker: Codable, Equatable, Sendable {}
extension PluginOption: Codable, Equatable, Sendable {}
extension PluginListScreen: Codable, Equatable, Sendable {}
extension PluginGridScreen: Codable, Equatable, Sendable {}
extension PluginSection: Codable, Equatable, Sendable, Identifiable {}
extension PluginRow: Codable, Equatable, Sendable, Identifiable {}
extension PluginEmptyState: Codable, Equatable, Sendable {}
extension PluginText: Codable, Equatable, Sendable {}
extension PluginAction: Codable, Equatable, Sendable, Identifiable {}
extension PluginShortcut: Codable, Equatable, Sendable, Hashable {}
extension PluginDetailScreen: Codable, Equatable, Sendable {}
extension PluginTag: Codable, Equatable, Sendable {}
extension PluginFormScreen: Codable, Equatable, Sendable {}
extension PluginField: Codable, Equatable, Sendable, Identifiable {}
extension PluginMenuBarScreen: Codable, Equatable, Sendable {}
extension PluginMenuItem: Codable, Equatable, Sendable, Identifiable {}
extension PluginMenuAlternate: Codable, Equatable, Sendable {}
extension PluginImageFit: Codable, Sendable {}
extension PluginGridInset: Codable, Sendable {}
extension PluginImageMask: Codable, Sendable {}
extension PluginDateStyle: Codable, Sendable {}
extension PluginSemanticColor: Codable, Sendable {}
extension PluginActionRole: Codable, Sendable {}
extension PluginModifier: Codable, Sendable, Hashable {}
extension PluginScreen: Codable, Equatable, Sendable {}
extension PluginAccessory: Codable, Equatable, Sendable {}
extension PluginTextContent: Codable, Equatable, Sendable {}
extension PluginImage: Codable, Equatable, Sendable {}
extension PluginColor: Codable, Equatable, Sendable {}
extension PluginEffect: Codable, Equatable, Sendable {}
extension PluginKey: Codable, Equatable, Sendable, Hashable {}
extension PluginMetadataItem: Codable, Equatable, Sendable {}
extension PluginFieldKind: Codable, Equatable, Sendable {}
extension PluginFieldValue: Codable, Equatable, Sendable {}
extension PluginMenuItemKind: Codable, Equatable, Sendable {}
extension PluginEvent: Codable, Equatable, Sendable {}
