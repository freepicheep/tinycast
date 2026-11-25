import AppKit
import SwiftUI

/// A plugin's image: an SF Symbol, an emoji, a colour swatch, a file or an app's icon, or a picture
/// from the web.
struct PluginImageView: View {
    let image: PluginImage
    var size: CGFloat = 16

    var body: some View {
        switch image {
        case .symbol(let name, let color):
            Image(systemName: name)
                .resizable()
                .scaledToFit()
                .foregroundStyle(color.map(PluginColors.color) ?? Color.secondary)
                .frame(width: size, height: size)
        case .emoji(let text):
            Text(text)
                .font(.system(size: size * 0.9))
                .frame(width: size, height: size)
        case .color(let color):
            RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                .fill(PluginColors.color(color))
                .frame(width: size, height: size)
        case .file, .fileIcon, .asset:
            if let picture = PluginImages.nsImage(image, size: size) {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                placeholder
            }
        case .remote(let url, let mask):
            AsyncImage(url: URL(string: url)) { phase in
                if let picture = phase.image {
                    masked(picture.resizable().scaledToFill(), mask)
                } else {
                    placeholder
                }
            }
            .frame(width: size, height: size)
        case .unsupported:
            placeholder
        }
    }

    @ViewBuilder
    private func masked(_ picture: some View, _ mask: PluginImageMask?) -> some View {
        switch mask {
        case .circle?: picture.clipShape(.circle)
        case .roundedRectangle?: picture.clipShape(.rect(cornerRadius: size / 5, style: .continuous))
        case nil: picture
        }
    }

    private var placeholder: some View {
        Image(systemName: "puzzlepiece")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
    }
}

/// Plugin images where AppKit wants an `NSImage`: a menu-bar item and its menu.
@MainActor
enum PluginImages {
    static func nsImage(_ image: PluginImage, size: CGFloat) -> NSImage? {
        let made: NSImage?
        switch image {
        case .symbol(let name, _):
            made = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            made?.isTemplate = true
        case .file(let path):
            made = NSImage(contentsOf: PluginEffects.fileURL(path))
        case .fileIcon(let path):
            made = NSWorkspace.shared.icon(forFile: PluginEffects.fileURL(path).path)
        case .asset(let name):
            made = NSImage(named: name)
        case .emoji(let text):
            made = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size * 0.85)])
                return true
            }
        case .color, .remote, .unsupported:
            made = nil
        }
        made?.size = NSSize(width: size, height: size)
        return made
    }
}

enum PluginColors {
    static func color(_ color: PluginColor) -> Color {
        switch color {
        case .rgba(let red, let green, let blue, let alpha): Color(red: red, green: green, blue: blue, opacity: alpha)
        case .semantic(let semantic): self.semantic(semantic)
        case .unsupported: .secondary
        }
    }

    private static func semantic(_ color: PluginSemanticColor) -> Color {
        switch color {
        case .primary: .primary
        case .secondary: .secondary
        case .accent: .accentColor
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }
}

/// A plugin's shortcut as SwiftUI and AppKit spell keys.
enum PluginShortcuts {
    static func keyEquivalent(_ key: PluginKey) -> KeyEquivalent? {
        switch key {
        case .character(let text): text.lowercased().first.map { KeyEquivalent($0) }
        case .returnKey: .return
        case .delete: .delete
        case .deleteForward: .deleteForward
        case .tab: .tab
        case .space: .space
        case .escape: .escape
        case .upArrow: .upArrow
        case .downArrow: .downArrow
        case .leftArrow: .leftArrow
        case .rightArrow: .rightArrow
        case .unsupported: nil
        }
    }

    static func modifiers(_ modifiers: [PluginModifier]) -> EventModifiers {
        var result: EventModifiers = []
        for modifier in modifiers {
            switch modifier {
            case .command: result.insert(.command)
            case .shift: result.insert(.shift)
            case .option: result.insert(.option)
            case .control: result.insert(.control)
            }
        }
        return result
    }

    static func modifierMask(_ modifiers: [PluginModifier]) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        for modifier in modifiers {
            switch modifier {
            case .command: result.insert(.command)
            case .shift: result.insert(.shift)
            case .option: result.insert(.option)
            case .control: result.insert(.control)
            }
        }
        return result
    }

    /// The menu's spelling of the key: a character, or the one AppKit uses for a named key.
    static func menuKey(_ key: PluginKey) -> String {
        switch key {
        case .character(let text): text.lowercased()
        case .returnKey: "\r"
        case .delete: "\u{8}"
        case .deleteForward: "\u{7F}"
        case .tab: "\t"
        case .space: " "
        case .escape: "\u{1B}"
        case .upArrow: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        case .downArrow: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case .leftArrow: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case .rightArrow: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case .unsupported: ""
        }
    }

    /// `⌘⇧P`, as a footer or a panel row shows a shortcut.
    static func display(_ shortcut: PluginShortcut) -> String {
        let order: [(PluginModifier, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let modifiers = order.filter { shortcut.modifiers.contains($0.0) }.map(\.1).joined()
        let key: String =
            switch shortcut.key {
            case .character(let text): text.uppercased()
            case .returnKey: "↵"
            case .delete: "⌫"
            case .deleteForward: "⌦"
            case .tab: "⇥"
            case .space: "␣"
            case .escape: "⎋"
            case .upArrow: "↑"
            case .downArrow: "↓"
            case .leftArrow: "←"
            case .rightArrow: "→"
            case .unsupported: ""
            }
        return modifiers + key
    }
}
