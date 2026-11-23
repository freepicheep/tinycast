import Foundation
import Scrift

// What a plugin's views render into. They cross the Scrift boundary as typed copies, shaped like the
// `@raycast/api` components the Extensions renderer draws, and a handler is the script's own
// closure, called directly: no serialization, no handler table on the script's side.

/// One component: `List`, `List.Item`, `Form.TextField`, `Action`, `MenuBarExtra.Item`, …
@ScriftExport
struct PluginNode {
    var type: String
    /// Tells this node apart from its siblings across renders, so the palette keeps its selection
    /// and a field keeps its focus; the position among siblings of its type when nil.
    var key: String?
    var props: [String: PluginValue]
    var children: [PluginNode]
}

/// A component's prop: plain values, nested components (`actions`, `detail`, `metadata`), and
/// handlers the palette calls with their arguments.
@ScriftExport
indirect enum PluginValue {
    case string(String)
    case number(Double)
    case bool(Bool)
    /// Seconds since 1970, which is how a date crosses: `Date` itself is a Foundation type.
    case date(Double)
    case array([PluginValue])
    case object([String: PluginValue])
    case node(PluginNode)
    /// An action's body, a field's edit, a search keystroke: called with what the palette passes.
    case handler(([PluginValue]) throws -> Void)
    case null
}

/// What a command starts with: its launch's arguments and context, and its preferences.
@ScriftExport
struct PluginLaunch {
    var commandName: String
    /// `userInitiated` or `background`, as Raycast's `LaunchType` spells it.
    var launchType: String
    var arguments: [String: String]
    var preferences: [String: PluginValue]
    var fallbackText: String?
    var launchContext: [String: PluginValue]
    var isDarkAppearance: Bool
}
