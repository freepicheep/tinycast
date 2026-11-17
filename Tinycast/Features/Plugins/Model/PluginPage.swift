import Stir

// The values a plugin's views render into. They cross the Stir boundary as typed copies, and an
// action is the script's own closure, called directly: no tree diffing, no handler table.

/// The top of a command's navigation stack.
@StirExport
enum PluginPage {
    case list(PluginList)
    case detail(PluginDetail)
}

@StirExport
struct PluginList {
    var title: String?
    var searchPrompt: String?
    /// Set when the plugin filters for itself with `.searchable(text:)`; nil lets Tinycast filter.
    var search: PluginSearch?
    var isLoading: Bool
    /// What an empty list says, from a `ContentUnavailableView` among its rows.
    var emptyText: String?
    var emptySymbol: String?
    var sections: [PluginSection]
}

@StirExport
struct PluginSearch {
    var text: String
    var onChange: (String) throws -> Void
}

@StirExport
struct PluginSection {
    var title: String?
    var items: [PluginItem]
}

@StirExport
struct PluginItem {
    var id: String
    var title: String
    var subtitle: String?
    var icon: PluginIcon?
    /// Trailing text, from `.badge(_:)`.
    var badges: [String]
    var keywords: [String]
    /// Shown beside the list while this item is selected.
    var detail: PluginDetail?
    var actions: [PluginAction]
}

@StirExport
enum PluginIcon {
    /// An SF Symbol and an optional tint name (`blue`, `orange`, …).
    case symbol(String, String?)
    /// A short string drawn as the icon, usually one emoji.
    case text(String)
}

@StirExport
struct PluginDetail {
    var title: String?
    var markdown: String
    var metadata: [PluginMetadataEntry]
    var actions: [PluginAction]
    var isLoading: Bool
}

@StirExport
struct PluginMetadataEntry {
    var label: String
    var value: String
}

@StirExport
struct PluginAction {
    var title: String
    var systemImage: String?
    /// One key, as typed (`"c"`, `"return"`, `"delete"`), held with `modifiers`.
    var shortcutKey: String?
    var modifiers: [String]
    var isDestructive: Bool
    var kind: PluginActionKind
}

@StirExport
enum PluginActionKind {
    /// The plugin's own code: a `Button`'s action or a `NavigationLink`'s push.
    case perform(() throws -> Void)
    /// Tinycast acts without calling back into the script, so these need no permission.
    case copy(String)
    case paste(String)
    case open(String)
}
