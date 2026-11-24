import Foundation

// The contract's JSON: a struct is an object of its fields; an enum case is an object whose `kind`
// names the case, beside its values. A kind this build doesn't know decodes as `unsupported`, and a
// field it doesn't know is skipped, so a host reads any newer minor version of its major.


/// The keys every enum case may use: `kind`, and its values by role.
private enum Wire: String, CodingKey {
    case kind, value, name, color, url, mask, path, text, icon, tooltip, style, application, concealed
    case title, generation, node, prompt, isSecure, isOn, picker, options, selection, includesTime
    case allowsMultiple, choosesDirectories, choosesFiles, red, green, blue, alpha, tags
}

/// A case without values, by name; an unknown name decodes as `fallback`.
private protocol PluginWireName: Equatable {
    static var names: [(String, Self)] { get }
    static var fallback: Self { get }
}

extension PluginWireName {
    var wireName: String { Self.names.first { $0.1 == self }?.0 ?? "" }

    static func named(_ name: String) -> Self { names.first { $0.0 == name }?.1 ?? fallback }
}

private func encodeName<T: PluginWireName>(_ value: T, to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value.wireName)
}

private func decodeName<T: PluginWireName>(from decoder: any Decoder) throws -> T {
    T.named(try decoder.singleValueContainer().decode(String.self))
}

extension PluginImageFit: PluginWireName {
    fileprivate static let names: [(String, Self)] = [("contain", .contain), ("fill", .fill)]
    fileprivate static let fallback = Self.contain
    init(from decoder: any Decoder) throws { self = try decodeName(from: decoder) }
    func encode(to encoder: any Encoder) throws { try encodeName(self, to: encoder) }
}

extension PluginGridInset: PluginWireName {
    fileprivate static let names: [(String, Self)] = [
        ("none", .none), ("small", .small), ("medium", .medium), ("large", .large),
    ]
    fileprivate static let fallback = Self.none
    init(from decoder: any Decoder) throws { self = try decodeName(from: decoder) }
    func encode(to encoder: any Encoder) throws { try encodeName(self, to: encoder) }
}

extension PluginImageMask: PluginWireName {
    fileprivate static let names: [(String, Self)] = [("circle", .circle), ("roundedRectangle", .roundedRectangle)]
    fileprivate static let fallback = Self.roundedRectangle
    init(from decoder: any Decoder) throws { self = try decodeName(from: decoder) }
    func encode(to encoder: any Encoder) throws { try encodeName(self, to: encoder) }
}

extension PluginDateStyle: PluginWireName {
    fileprivate static let names: [(String, Self)] = [
        ("relative", .relative), ("offset", .offset), ("timer", .timer), ("date", .date), ("time", .time),
    ]
    fileprivate static let fallback = Self.date
    init(from decoder: any Decoder) throws { self = try decodeName(from: decoder) }
    func encode(to encoder: any Encoder) throws { try encodeName(self, to: encoder) }
}

extension PluginSemanticColor: PluginWireName {
    fileprivate static let names: [(String, Self)] = [
        ("primary", .primary), ("secondary", .secondary), ("accent", .accent), ("red", .red),
        ("orange", .orange), ("yellow", .yellow), ("green", .green), ("mint", .mint), ("teal", .teal),
        ("cyan", .cyan), ("blue", .blue), ("indigo", .indigo), ("purple", .purple), ("pink", .pink),
        ("brown", .brown), ("gray", .gray),
    ]
    fileprivate static let fallback = Self.primary
    init(from decoder: any Decoder) throws { self = try decodeName(from: decoder) }
    func encode(to encoder: any Encoder) throws { try encodeName(self, to: encoder) }
}

extension PluginActionRole: PluginWireName {
    fileprivate static let names: [(String, Self)] = [("destructive", .destructive), ("cancel", .cancel)]
    fileprivate static let fallback = Self.cancel
    init(from decoder: any Decoder) throws { self = try decodeName(from: decoder) }
    func encode(to encoder: any Encoder) throws { try encodeName(self, to: encoder) }
}

extension PluginModifier: PluginWireName {
    fileprivate static let names: [(String, Self)] = [
        ("command", .command), ("shift", .shift), ("option", .option), ("control", .control),
    ]
    fileprivate static let fallback = Self.command
    init(from decoder: any Decoder) throws { self = try decodeName(from: decoder) }
    func encode(to encoder: any Encoder) throws { try encodeName(self, to: encoder) }
}

extension PluginScreen {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Wire.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "list": self = .list(try container.decode(PluginListScreen.self, forKey: .value))
        case "grid": self = .grid(try container.decode(PluginGridScreen.self, forKey: .value))
        case "detail": self = .detail(try container.decode(PluginDetailScreen.self, forKey: .value))
        case "form": self = .form(try container.decode(PluginFormScreen.self, forKey: .value))
        case "menuBar": self = .menuBar(try container.decode(PluginMenuBarScreen.self, forKey: .value))
        case let other: self = .unsupported(other)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Wire.self)
        switch self {
        case .list(let screen): try container.encode("list", forKey: .kind); try container.encode(screen, forKey: .value)
        case .grid(let screen): try container.encode("grid", forKey: .kind); try container.encode(screen, forKey: .value)
        case .detail(let screen):
            try container.encode("detail", forKey: .kind)
            try container.encode(screen, forKey: .value)
        case .form(let screen): try container.encode("form", forKey: .kind); try container.encode(screen, forKey: .value)
        case .menuBar(let screen):
            try container.encode("menuBar", forKey: .kind)
            try container.encode(screen, forKey: .value)
        case .unsupported(let kind): try container.encode(kind, forKey: .kind)
        }
    }
}

extension PluginAccessory {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Wire.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "text": self = .text(try container.decode(PluginText.self, forKey: .text))
        case "count": self = .count(try container.decode(Int.self, forKey: .value))
        case "label":
            self = .label(
                try container.decode(PluginText.self, forKey: .text),
                icon: try container.decode(PluginImage.self, forKey: .icon))
        case "icon":
            self = .icon(
                try container.decode(PluginImage.self, forKey: .icon),
                tooltip: try container.decodeIfPresent(String.self, forKey: .tooltip))
        case "tag":
            self = .tag(
                try container.decode(String.self, forKey: .name),
                color: try container.decodeIfPresent(PluginColor.self, forKey: .color))
        case let other: self = .unsupported(other)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Wire.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .kind)
            try container.encode(text, forKey: .text)
        case .count(let count):
            try container.encode("count", forKey: .kind)
            try container.encode(count, forKey: .value)
        case .label(let text, let icon):
            try container.encode("label", forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encode(icon, forKey: .icon)
        case .icon(let icon, let tooltip):
            try container.encode("icon", forKey: .kind)
            try container.encode(icon, forKey: .icon)
            try container.encodeIfPresent(tooltip, forKey: .tooltip)
        case .tag(let name, let color):
            try container.encode("tag", forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(color, forKey: .color)
        case .unsupported(let kind): try container.encode(kind, forKey: .kind)
        }
    }
}

extension PluginTextContent {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Wire.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "plain": self = .plain(try container.decode(String.self, forKey: .text))
        case "date":
            self = .date(
                try container.decode(Double.self, forKey: .value),
                style: try container.decode(PluginDateStyle.self, forKey: .style))
        case let other: self = .unsupported(other)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Wire.self)
        switch self {
        case .plain(let text):
            try container.encode("plain", forKey: .kind)
            try container.encode(text, forKey: .text)
        case .date(let seconds, let style):
            try container.encode("date", forKey: .kind)
            try container.encode(seconds, forKey: .value)
            try container.encode(style, forKey: .style)
        case .unsupported(let kind): try container.encode(kind, forKey: .kind)
        }
    }
}

extension PluginImage {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Wire.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "symbol":
            self = .symbol(
                try container.decode(String.self, forKey: .name),
                color: try container.decodeIfPresent(PluginColor.self, forKey: .color))
        case "remote":
            self = .remote(
                try container.decode(String.self, forKey: .url),
                mask: try container.decodeIfPresent(PluginImageMask.self, forKey: .mask))
        case "file": self = .file(try container.decode(String.self, forKey: .path))
        case "fileIcon": self = .fileIcon(try container.decode(String.self, forKey: .path))
        case "asset": self = .asset(try container.decode(String.self, forKey: .name))
        case "emoji": self = .emoji(try container.decode(String.self, forKey: .text))
        case "color": self = .color(try container.decode(PluginColor.self, forKey: .color))
        case let other: self = .unsupported(other)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Wire.self)
        switch self {
        case .symbol(let name, let color):
            try container.encode("symbol", forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(color, forKey: .color)
        case .remote(let url, let mask):
            try container.encode("remote", forKey: .kind)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(mask, forKey: .mask)
        case .file(let path):
            try container.encode("file", forKey: .kind)
            try container.encode(path, forKey: .path)
        case .fileIcon(let path):
            try container.encode("fileIcon", forKey: .kind)
            try container.encode(path, forKey: .path)
        case .asset(let name):
            try container.encode("asset", forKey: .kind)
            try container.encode(name, forKey: .name)
        case .emoji(let text):
            try container.encode("emoji", forKey: .kind)
            try container.encode(text, forKey: .text)
        case .color(let color):
            try container.encode("color", forKey: .kind)
            try container.encode(color, forKey: .color)
        case .unsupported(let kind): try container.encode(kind, forKey: .kind)
        }
    }
}

extension PluginColor {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Wire.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "semantic": self = .semantic(try container.decode(PluginSemanticColor.self, forKey: .name))
        case "rgba":
            self = .rgba(
                try container.decode(Double.self, forKey: .red), try container.decode(Double.self, forKey: .green),
                try container.decode(Double.self, forKey: .blue), try container.decode(Double.self, forKey: .alpha))
        case let other: self = .unsupported(other)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Wire.self)
        switch self {
        case .semantic(let name):
            try container.encode("semantic", forKey: .kind)
            try container.encode(name, forKey: .name)
        case .rgba(let red, let green, let blue, let alpha):
            try container.encode("rgba", forKey: .kind)
            try container.encode(red, forKey: .red)
            try container.encode(green, forKey: .green)
            try container.encode(blue, forKey: .blue)
            try container.encode(alpha, forKey: .alpha)
        case .unsupported(let kind): try container.encode(kind, forKey: .kind)
        }
    }
}

extension PluginEffect {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Wire.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "openURL":
            self = .openURL(
                try container.decode(String.self, forKey: .url),
                application: try container.decodeIfPresent(String.self, forKey: .application))
        case "copy":
            self = .copy(
                try container.decode(String.self, forKey: .text),
                concealed: try container.decodeIfPresent(Bool.self, forKey: .concealed) ?? false)
        case "paste": self = .paste(try container.decode(String.self, forKey: .text))
        case "revealInFinder": self = .revealInFinder(try container.decode(String.self, forKey: .path))
        case "openWith": self = .openWith(try container.decode(String.self, forKey: .path))
        case "trash": self = .trash(try container.decode([String].self, forKey: .path))
        case "push": self = .push
        case "submit": self = .submit
        case "section": self = .section
        case "menu": self = .menu
        case let other: self = .unsupported(other)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Wire.self)
        switch self {
        case .openURL(let url, let application):
            try container.encode("openURL", forKey: .kind)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(application, forKey: .application)
        case .copy(let text, let concealed):
            try container.encode("copy", forKey: .kind)
            try container.encode(text, forKey: .text)
            if concealed { try container.encode(true, forKey: .concealed) }
        case .paste(let text):
            try container.encode("paste", forKey: .kind)
            try container.encode(text, forKey: .text)
        case .revealInFinder(let path):
            try container.encode("revealInFinder", forKey: .kind)
            try container.encode(path, forKey: .path)
        case .openWith(let path):
            try container.encode("openWith", forKey: .kind)
            try container.encode(path, forKey: .path)
        case .trash(let paths):
            try container.encode("trash", forKey: .kind)
            try container.encode(paths, forKey: .path)
        case .push: try container.encode("push", forKey: .kind)
        case .submit: try container.encode("submit", forKey: .kind)
        case .section: try container.encode("section", forKey: .kind)
        case .menu: try container.encode("menu", forKey: .kind)
        case .unsupported(let kind): try container.encode(kind, forKey: .kind)
        }
    }
}

extension PluginKey {
    private static let named: [(String, PluginKey)] = [
        ("return", .returnKey), ("delete", .delete), ("deleteForward", .deleteForward), ("tab", .tab),
        ("space", .space), ("escape", .escape), ("upArrow", .upArrow), ("downArrow", .downArrow),
        ("leftArrow", .leftArrow), ("rightArrow", .rightArrow),
    ]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Wire.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "character": self = .character(try container.decode(String.self, forKey: .text))
        case let other: self = Self.named.first { $0.0 == other }?.1 ?? .unsupported(other)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Wire.self)
        switch self {
        case .character(let text):
            try container.encode("character", forKey: .kind)
            try container.encode(text, forKey: .text)
        case .unsupported(let kind): try container.encode(kind, forKey: .kind)
        default: try container.encode(Self.named.first { $0.1 == self }?.0 ?? "", forKey: .kind)
        }
    }
}

extension PluginMetadataItem {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Wire.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "label":
            self = .label(
                try container.decode(String.self, forKey: .title), text: try container.decode(PluginText.self, forKey: .text),
                icon: try container.decodeIfPresent(PluginImage.self, forKey: .icon))
        case "link":
            self = .link(
                try container.decode(String.self, forKey: .title), text: try container.decode(String.self, forKey: .text),
                url: try container.decode(String.self, forKey: .url))
        case "tags":
            self = .tags(try container.decode(String.self, forKey: .title), try container.decode([PluginTag].self, forKey: .tags))
        case "separator": self = .separator
        case let other: self = .unsupported(other)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Wire.self)
        switch self {
        case .label(let title, let text, let icon):
            try container.encode("label", forKey: .kind)
            try container.encode(title, forKey: .title)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(icon, forKey: .icon)
        case .link(let title, let text, let url):
            try container.encode("link", forKey: .kind)
            try container.encode(title, forKey: .title)
            try container.encode(text, forKey: .text)
            try container.encode(url, forKey: .url)
        case .tags(let title, let tags):
            try container.encode("tags", forKey: .kind)
            try container.encode(title, forKey: .title)
            try container.encode(tags, forKey: .tags)
        case .separator: try container.encode("separator", forKey: .kind)
        case .unsupported(let kind): try container.encode(kind, forKey: .kind)
        }
    }
}

extension PluginFieldKind {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Wire.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "textField":
            self = .textField(
                try container.decode(String.self, forKey: .text),
                prompt: try container.decodeIfPresent(String.self, forKey: .prompt),
                isSecure: try container.decodeIfPresent(Bool.self, forKey: .isSecure) ?? false)
        case "textEditor":
            self = .textEditor(
                try container.decode(String.self, forKey: .text),
                prompt: try container.decodeIfPresent(String.self, forKey: .prompt))
        case "toggle":
            self = .toggle(try container.decode(String.self, forKey: .text), isOn: try container.decode(Bool.self, forKey: .isOn))
        case "picker": self = .picker(try container.decode(PluginPicker.self, forKey: .picker))
        case "multiPicker":
            self = .multiPicker(
                try container.decode([PluginOption].self, forKey: .options),
                selection: try container.decode([Int].self, forKey: .selection))
        case "datePicker":
            self = .datePicker(
                try container.decodeIfPresent(Double.self, forKey: .value),
                includesTime: try container.decode(Bool.self, forKey: .includesTime))
        case "filePicker":
            self = .filePicker(
                try container.decode([String].self, forKey: .path),
                allowsMultiple: try container.decode(Bool.self, forKey: .allowsMultiple),
                choosesDirectories: try container.decode(Bool.self, forKey: .choosesDirectories),
                choosesFiles: try container.decode(Bool.self, forKey: .choosesFiles))
        case "text": self = .text(try container.decode(String.self, forKey: .text))
        case "separator": self = .separator
        case let other: self = .unsupported(other)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Wire.self)
        switch self {
        case .textField(let text, let prompt, let isSecure):
            try container.encode("textField", forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(prompt, forKey: .prompt)
            if isSecure { try container.encode(true, forKey: .isSecure) }
        case .textEditor(let text, let prompt):
            try container.encode("textEditor", forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(prompt, forKey: .prompt)
        case .toggle(let label, let isOn):
            try container.encode("toggle", forKey: .kind)
            try container.encode(label, forKey: .text)
            try container.encode(isOn, forKey: .isOn)
        case .picker(let picker):
            try container.encode("picker", forKey: .kind)
            try container.encode(picker, forKey: .picker)
        case .multiPicker(let options, let selection):
            try container.encode("multiPicker", forKey: .kind)
            try container.encode(options, forKey: .options)
            try container.encode(selection, forKey: .selection)
        case .datePicker(let seconds, let includesTime):
            try container.encode("datePicker", forKey: .kind)
            try container.encodeIfPresent(seconds, forKey: .value)
            try container.encode(includesTime, forKey: .includesTime)
        case .filePicker(let paths, let allowsMultiple, let choosesDirectories, let choosesFiles):
            try container.encode("filePicker", forKey: .kind)
            try container.encode(paths, forKey: .path)
            try container.encode(allowsMultiple, forKey: .allowsMultiple)
            try container.encode(choosesDirectories, forKey: .choosesDirectories)
            try container.encode(choosesFiles, forKey: .choosesFiles)
        case .text(let text):
            try container.encode("text", forKey: .kind)
            try container.encode(text, forKey: .text)
        case .separator: try container.encode("separator", forKey: .kind)
        case .unsupported(let kind): try container.encode(kind, forKey: .kind)
        }
    }
}

extension PluginFieldValue {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Wire.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "text": self = .text(try container.decode(String.self, forKey: .value))
        case "bool": self = .bool(try container.decode(Bool.self, forKey: .value))
        case "index": self = .index(try container.decodeIfPresent(Int.self, forKey: .value))
        case "indices": self = .indices(try container.decode([Int].self, forKey: .value))
        case "date": self = .date(try container.decodeIfPresent(Double.self, forKey: .value))
        case "paths": self = .paths(try container.decode([String].self, forKey: .value))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "no field value of kind \(other)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Wire.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .kind)
            try container.encode(text, forKey: .value)
        case .bool(let flag):
            try container.encode("bool", forKey: .kind)
            try container.encode(flag, forKey: .value)
        case .index(let index):
            try container.encode("index", forKey: .kind)
            try container.encodeIfPresent(index, forKey: .value)
        case .indices(let indices):
            try container.encode("indices", forKey: .kind)
            try container.encode(indices, forKey: .value)
        case .date(let seconds):
            try container.encode("date", forKey: .kind)
            try container.encodeIfPresent(seconds, forKey: .value)
        case .paths(let paths):
            try container.encode("paths", forKey: .kind)
            try container.encode(paths, forKey: .value)
        }
    }
}

extension PluginMenuItemKind {
    init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "item": self = .item
        case "section": self = .section
        case "submenu": self = .submenu
        case "separator": self = .separator
        case let other: self = .unsupported(other)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .item: try container.encode("item")
        case .section: try container.encode("section")
        case .submenu: try container.encode("submenu")
        case .separator: try container.encode("separator")
        case .unsupported(let kind): try container.encode(kind)
        }
    }
}

extension PluginEvent {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Wire.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "perform":
            self = .perform(try container.decode(Int.self, forKey: .value), generation: try container.decode(Int.self, forKey: .generation))
        case "set":
            self = .set(
                try container.decode(String.self, forKey: .node), value: try container.decode(PluginFieldValue.self, forKey: .value),
                generation: try container.decode(Int.self, forKey: .generation))
        case "search":
            self = .search(try container.decode(String.self, forKey: .text), generation: try container.decode(Int.self, forKey: .generation))
        case "back": self = .back
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "no event of kind \(other)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Wire.self)
        switch self {
        case .perform(let handler, let generation):
            try container.encode("perform", forKey: .kind)
            try container.encode(handler, forKey: .value)
            try container.encode(generation, forKey: .generation)
        case .set(let node, let value, let generation):
            try container.encode("set", forKey: .kind)
            try container.encode(node, forKey: .node)
            try container.encode(value, forKey: .value)
            try container.encode(generation, forKey: .generation)
        case .search(let text, let generation):
            try container.encode("search", forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encode(generation, forKey: .generation)
        case .back: try container.encode("back", forKey: .kind)
        }
    }
}
