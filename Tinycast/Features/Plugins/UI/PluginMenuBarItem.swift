import AppKit

/// One menu-bar command's status item: its title or icon, and the menu its last frame describes.
/// Choosing an item sends its handler back with the generation the menu was built from.
@MainActor
final class PluginMenuBarItem: NSObject {
    var onPerform: (_ handler: Int, _ generation: Int) -> Void = { _, _ in }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let fallbackTitle: String
    private var generation = 0

    init(title: String) {
        fallbackTitle = title
        super.init()
        statusItem.button?.title = title
    }

    func show(_ screen: PluginMenuBarScreen, generation: Int) {
        self.generation = generation
        guard let button = statusItem.button else { return }
        let image = screen.icon.flatMap { PluginImages.nsImage($0, size: 16) }
        let title = screen.title ?? ""
        button.image = image
        button.title = title.isEmpty && image == nil ? fallbackTitle : title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.toolTip = screen.tooltip
        let menu = NSMenu()
        if screen.isLoading && screen.items.isEmpty {
            let loading = NSMenuItem(title: String(localized: "Loading…"), action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.addItem(loading)
        }
        add(screen.items, to: menu)
        statusItem.menu = menu
    }

    func showFailure(_ message: String) {
        statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        statusItem.button?.title = ""
        statusItem.button?.toolTip = message
        let menu = NSMenu()
        let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        statusItem.menu = menu
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func add(_ items: [PluginMenuItem], to menu: NSMenu) {
        for item in items {
            switch item.kind {
            case .separator:
                menu.addItem(.separator())
            case .section:
                if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
                if !item.title.isEmpty { menu.addItem(.sectionHeader(title: item.title)) }
                add(item.children, to: menu)
            case .submenu:
                let entry = menuItem(item.title, subtitle: item.subtitle, icon: item.icon, handler: nil)
                let submenu = NSMenu(title: item.title)
                add(item.children, to: submenu)
                entry.submenu = submenu
                menu.addItem(entry)
            case .item:
                let entry = menuItem(item.title, subtitle: item.subtitle, icon: item.icon, handler: item.handler)
                entry.toolTip = item.tooltip
                if let shortcut = item.shortcut {
                    entry.keyEquivalent = PluginShortcuts.menuKey(shortcut.key)
                    entry.keyEquivalentModifierMask = PluginShortcuts.modifierMask(shortcut.modifiers)
                }
                menu.addItem(entry)
                if let alternate = item.alternate {
                    let shown = menuItem(
                        alternate.title, subtitle: alternate.subtitle, icon: alternate.icon, handler: alternate.handler)
                    shown.isAlternate = true
                    shown.keyEquivalent = entry.keyEquivalent
                    shown.keyEquivalentModifierMask = entry.keyEquivalentModifierMask.union(.option)
                    menu.addItem(shown)
                }
            case .unsupported:
                continue
            }
        }
    }

    private func menuItem(_ title: String, subtitle: String?, icon: PluginImage?, handler: Int?) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: handler == nil ? nil : #selector(choose(_:)), keyEquivalent: "")
        entry.target = self
        entry.tag = handler ?? 0
        entry.subtitle = subtitle
        entry.image = icon.flatMap { PluginImages.nsImage($0, size: 16) }
        return entry
    }

    @objc private func choose(_ sender: NSMenuItem) {
        onPerform(sender.tag, generation)
    }
}
