// A menu-bar command's body: the status item, and the menu its buttons, sections and menus make.

import Foundation
import _TinycastHost

/// The status item a `Plugin.menuBar` command shows: a title, an icon or both, and its menu of
/// `Button`s, `Section`s, `Menu`s and `Divider`s.
public struct MenuBarExtra: _PrimitiveView {
    let screen: _Screen

    public init<Content: View>(_ title: String? = nil, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        screen = _Screen(.menuBar, content: _resolve(content()))
        screen.title = title
        screen.icon = systemImage.map { PluginImage.symbol($0, color: nil) }
    }

    public var _parts: [_Part] { [screen.part] }
}
