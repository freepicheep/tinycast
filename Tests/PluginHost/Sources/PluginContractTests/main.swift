// The plugin view contract (Features/Plugins/Model/PluginUI.swift): every case's JSON against its golden file
// in Fixtures/contract, a round trip of each, and a frame from a newer minor version read by this one.
// `UPDATE_GOLDEN=1` rewrites the golden files.
import Foundation

nonisolated(unsafe) var failures = 0

func check(_ condition: Bool, _ name: String) {
    if condition {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../Fixtures/contract").standardized
let update = ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] == "1"

func json<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    return String(decoding: try! encoder.encode(value), as: UTF8.self) + "\n"
}

/// Each sample against `<name>.json`, then decoded back into an equal value.
func golden<T: Codable & Equatable>(_ name: String, _ samples: [T]) {
    let file = fixtures.appending(path: "\(name).json")
    let written = json(samples)
    if update { try! written.write(to: file, atomically: true, encoding: .utf8) }
    let expected = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    check(written == expected, "\(name) encodes as its golden file")
    let decoded = try? JSONDecoder().decode([T].self, from: Data(expected.utf8))
    check(decoded == samples, "\(name) decodes back from it")
}

func text(_ string: String) -> PluginText {
    PluginText(content: .plain(string), color: nil, isBold: false, isMonospaced: false)
}

let blue = PluginColor.semantic(.blue)
let symbol = PluginImage.symbol("star", color: blue)
let open = PluginAction(
    id: "open", title: "Open", icon: symbol,
    shortcut: PluginShortcut(key: .character("o"), modifiers: [.command, .shift]), role: nil,
    effect: .openURL("https://example.com", application: "Safari"), handler: nil, children: [])
let chrome = PluginChrome(
    title: "Stories", search: PluginSearchField(text: "swift", prompt: "Search", binding: "search"),
    pickers: [
        PluginPicker(
            id: "feed", title: "Feed",
            options: [
                PluginOption(title: "Front Page", icon: symbol, section: nil),
                PluginOption(title: "Newest", icon: nil, section: "More"),
            ], selection: 1)
    ], actions: [open], isLoading: true)
let row = PluginRow(
    id: "row-1", title: text("A story"), subtitle: text("example.com"), icon: symbol, content: nil,
    accessories: [.count(12)], keywords: ["swift"], actions: [open], detail: nil, isRedacted: false)
let detail = PluginDetailScreen(
    chrome: PluginChrome(title: "Detail", search: nil, pickers: [], actions: [open], isLoading: false),
    markdown: "# Title", metadata: [.separator])

golden("color", [PluginColor.semantic(.accent), .rgba(0.1, 0.2, 0.3, 1), .unsupported("p3")])
golden(
    "semantic-color",
    [PluginSemanticColor.primary, .secondary, .accent, .red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue,
     .indigo, .purple, .pink, .brown, .gray])
golden(
    "image",
    [
        PluginImage.symbol("star", color: nil), symbol, .remote("https://example.com/a.png", mask: .circle),
        .remote("https://example.com/b.png", mask: .roundedRectangle), .file("/tmp/a.png"),
        .fileIcon("/Applications/Safari.app"), .asset("icon.png"), .emoji("👋"), .color(blue), .unsupported("video"),
    ])
golden(
    "text",
    [
        text("plain"),
        PluginText(content: .date(1_700_000_000, style: .relative), color: .semantic(.secondary), isBold: true, isMonospaced: true),
        PluginText(content: .date(0, style: .offset), color: nil, isBold: false, isMonospaced: false),
        PluginText(content: .date(0, style: .timer), color: nil, isBold: false, isMonospaced: false),
        PluginText(content: .date(0, style: .date), color: nil, isBold: false, isMonospaced: false),
        PluginText(content: .date(0, style: .time), color: nil, isBold: false, isMonospaced: false),
        PluginText(content: .unsupported("markdown"), color: nil, isBold: false, isMonospaced: false),
    ])
golden(
    "accessory",
    [
        PluginAccessory.text(text("3h")), .count(42), .label(text("12"), icon: symbol), .icon(symbol, tooltip: "Starred"),
        .icon(symbol, tooltip: nil), .tag("new", color: .semantic(.green)), .tag("plain", color: nil), .unsupported("meter"),
    ])
golden(
    "key",
    [
        PluginKey.character("k"), .returnKey, .delete, .deleteForward, .tab, .space, .escape, .upArrow, .downArrow,
        .leftArrow, .rightArrow, .unsupported("f13"),
    ])
golden(
    "shortcut",
    [PluginShortcut(key: .returnKey, modifiers: [.command, .shift, .option, .control])])
golden(
    "action",
    [
        open,
        PluginAction(
            id: "copy", title: "Copy", icon: nil, shortcut: nil, role: nil, effect: .copy("text", concealed: true),
            handler: nil, children: []),
        PluginAction(
            id: "paste", title: "Paste", icon: nil, shortcut: nil, role: nil, effect: .paste("text"), handler: nil,
            children: []),
        PluginAction(
            id: "reveal", title: "Show in Finder", icon: nil, shortcut: nil, role: nil, effect: .revealInFinder("/tmp"),
            handler: nil, children: []),
        PluginAction(
            id: "with", title: "Open With", icon: nil, shortcut: nil, role: nil, effect: .openWith("/tmp/a.txt"),
            handler: nil, children: []),
        PluginAction(
            id: "trash", title: "Move to Trash", icon: nil, shortcut: nil, role: .destructive,
            effect: .trash(["/tmp/a", "/tmp/b"]), handler: 7, children: []),
        PluginAction(
            id: "push", title: "Details", icon: nil, shortcut: nil, role: nil, effect: .push, handler: 3, children: []),
        PluginAction(
            id: "submit", title: "Submit", icon: nil, shortcut: nil, role: nil, effect: .submit, handler: 4, children: []),
        PluginAction(
            id: "run", title: "Run", icon: nil, shortcut: nil, role: .cancel, effect: nil, handler: 5, children: []),
        PluginAction(
            id: "section", title: "Links", icon: nil, shortcut: nil, role: nil, effect: .section, handler: nil,
            children: [open]),
        PluginAction(
            id: "menu", title: "More", icon: symbol, shortcut: nil, role: nil, effect: .menu, handler: nil,
            children: [open]),
        PluginAction(
            id: "new", title: "New", icon: nil, shortcut: nil, role: nil, effect: .unsupported("share"), handler: nil,
            children: []),
    ])
golden(
    "metadata",
    [
        PluginMetadataItem.label("Author", text: text("pg"), icon: symbol), .label("Points", text: text("12"), icon: nil),
        .link("Source", text: "example.com", url: "https://example.com"),
        .tags("Topics", [PluginTag(text: "swift", color: blue), PluginTag(text: "plain", color: nil)]), .separator,
        .unsupported("chart"),
    ])
golden(
    "field",
    [
        PluginField(
            id: "name", title: "Name", info: "Who", error: "Required", autoFocus: true,
            kind: .textField("Ann", prompt: "Your name", isSecure: false)),
        PluginField(
            id: "secret", title: "Password", info: nil, error: nil, autoFocus: false,
            kind: .textField("", prompt: nil, isSecure: true)),
        PluginField(
            id: "notes", title: "Notes", info: nil, error: nil, autoFocus: false, kind: .textEditor("hi", prompt: "Notes")),
        PluginField(id: "on", title: "Enabled", info: nil, error: nil, autoFocus: false, kind: .toggle("Turn on", isOn: true)),
        PluginField(id: "feed", title: nil, info: nil, error: nil, autoFocus: false, kind: .picker(chrome.pickers[0])),
        PluginField(
            id: "tags", title: "Tags", info: nil, error: nil, autoFocus: false,
            kind: .multiPicker(chrome.pickers[0].options, selection: [0, 1])),
        PluginField(
            id: "when", title: "When", info: nil, error: nil, autoFocus: false,
            kind: .datePicker(1_700_000_000, includesTime: true)),
        PluginField(
            id: "never", title: "Never", info: nil, error: nil, autoFocus: false, kind: .datePicker(nil, includesTime: false)),
        PluginField(
            id: "files", title: "Files", info: nil, error: nil, autoFocus: false,
            kind: .filePicker(["/tmp"], allowsMultiple: true, choosesDirectories: false, choosesFiles: true)),
        PluginField(id: "about", title: nil, info: nil, error: nil, autoFocus: false, kind: .text("Some words")),
        PluginField(id: "line", title: nil, info: nil, error: nil, autoFocus: false, kind: .separator),
        PluginField(id: "slider", title: nil, info: nil, error: nil, autoFocus: false, kind: .unsupported("slider")),
    ])
golden(
    "field-value",
    [
        PluginFieldValue.text("a"), .bool(true), .index(2), .index(nil), .indices([0, 3]), .date(12.5), .date(nil),
        .paths(["/tmp"]),
    ])
golden(
    "menu-item",
    [
        PluginMenuItem(
            id: "top", kind: .item, title: "Top story", subtitle: "12 points", icon: symbol, tooltip: "Open",
            shortcut: PluginShortcut(key: .character("1"), modifiers: [.command]), handler: 1,
            alternate: PluginMenuAlternate(title: "Comments", subtitle: nil, icon: nil, handler: 2), children: []),
        PluginMenuItem(
            id: "section", kind: .section, title: "Stories", subtitle: nil, icon: nil, tooltip: nil, shortcut: nil,
            handler: nil, alternate: nil, children: []),
        PluginMenuItem(
            id: "more", kind: .submenu, title: "More", subtitle: nil, icon: nil, tooltip: nil, shortcut: nil, handler: nil,
            alternate: nil, children: []),
        PluginMenuItem(
            id: "line", kind: .separator, title: "", subtitle: nil, icon: nil, tooltip: nil, shortcut: nil, handler: nil,
            alternate: nil, children: []),
        PluginMenuItem(
            id: "slider", kind: .unsupported("slider"), title: "", subtitle: nil, icon: nil, tooltip: nil, shortcut: nil,
            handler: nil, alternate: nil, children: []),
    ])
golden(
    "screen",
    [
        PluginScreen.list(
            PluginListScreen(
                chrome: chrome,
                sections: [PluginSection(id: "top", title: "Top", subtitle: "Today", rows: [row])],
                emptyState: PluginEmptyState(title: "No Stories", description: "Try later", icon: symbol, actions: [open]),
                showsDetail: true, selection: "row-1", selectionBinding: "selection")),
        .grid(
            PluginGridScreen(
                chrome: chrome, sections: [PluginSection(id: "s", title: nil, subtitle: nil, rows: [row])], emptyState: nil,
                columns: 5, aspectRatio: 1.5, fit: .fill, inset: .medium, selection: nil, selectionBinding: nil)),
        .detail(detail),
        .form(
            PluginFormScreen(
                chrome: PluginChrome(title: "Form", search: nil, pickers: [], actions: [open], isLoading: false),
                fields: [
                    PluginField(
                        id: "name", title: "Name", info: nil, error: nil, autoFocus: true,
                        kind: .textField("", prompt: nil, isSecure: false))
                ])),
        .menuBar(
            PluginMenuBarScreen(
                title: "HN", icon: symbol, tooltip: "Hacker News", isLoading: false,
                items: [
                    PluginMenuItem(
                        id: "a", kind: .item, title: "A", subtitle: nil, icon: nil, tooltip: nil, shortcut: nil, handler: 1,
                        alternate: nil, children: [])
                ])),
        .unsupported("carousel"),
    ])
golden("grid-inset", [PluginGridInset.none, .small, .medium, .large])
golden("image-fit", [PluginImageFit.contain, .fill])
golden("date-style", [PluginDateStyle.relative, .offset, .timer, .date, .time])
golden("modifier", [PluginModifier.command, .shift, .option, .control])
golden(
    "event",
    [
        PluginEvent.perform(3, generation: 9), .set("feed", value: .index(1), generation: 9),
        .search("swift", generation: 10), .back,
    ])
golden(
    "frame",
    [PluginFrame(version: .current, generation: 4, depth: 2, screen: .detail(detail))])

// A frame from version 1.7: new fields everywhere, new kinds of screen, image, accessory and effect.
let newer = try! JSONDecoder().decode(
    [PluginFrame].self, from: Data(contentsOf: fixtures.appending(path: "newer-minor.json")))
check(newer.count == 2, "a newer minor version's frames decode")
if case .list(let list) = newer.first?.screen {
    let row = list.sections.first?.rows.first
    check(row?.icon == .unsupported("hologram"), "an unknown image kind is a placeholder")
    check(row?.accessories == [.count(2), .unsupported("meter")], "an unknown accessory is a placeholder beside known ones")
    check(row?.actions.first?.effect == .unsupported("share"), "an unknown effect is a placeholder")
    check(row?.title.content == .plain("Kept"), "known fields beside unknown ones keep their values")
} else {
    check(false, "the newer frame's screen is a list")
}
check(newer.last?.screen == .unsupported("carousel"), "an unknown screen is a placeholder")

if failures > 0 {
    print("\(failures) contract checks failed.")
    exit(1)
}
print("All contract checks passed.")
