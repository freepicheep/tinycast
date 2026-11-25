// Forms: fields bound to the command's state, as SwiftUI's. Each field's value is a `Binding`, so
// the form reads and writes the command's own `@State` or `@AppStorage`.

import Foundation
import _TinycastHost

/// A screen of fields; its `.toolbar`'s first button runs on ⌘Return.
public struct Form: _PrimitiveView {
    let screen: _Screen

    public init<Content: View>(@ViewBuilder content: () -> Content) {
        screen = _Screen(.form, content: _resolve(content()))
    }

    public var _parts: [_Part] { [screen.part] }
}

/// A field's kind as drawn, and what its edits set.
public final class _Field {
    let kind: PluginFieldKind
    let set: (PluginFieldValue) -> Void

    init(_ kind: PluginFieldKind, set: @escaping (PluginFieldValue) -> Void) {
        self.kind = kind
        self.set = set
    }
}

func _field(_ title: String, _ kind: PluginFieldKind, set: @escaping (PluginFieldValue) -> Void) -> _Part {
    var part = _Part(.field)
    part.title = title
    part.field = _Field(kind, set: set)
    return part
}

func _textSetter(_ binding: Binding<String>) -> (PluginFieldValue) -> Void {
    { value in
        if case .text(let text) = value { binding.wrappedValue = text }
    }
}

public enum Axis {
    case horizontal
    case vertical
}

/// A line of text; `axis: .vertical` grows to several lines.
public struct TextField: _PrimitiveView {
    let part: _Part

    public init(_ title: String, text: Binding<String>, prompt: Text? = nil, axis: Axis = .horizontal) {
        let kind: PluginFieldKind =
            axis == .vertical
            ? .textEditor(text.wrappedValue, prompt: prompt?.plain)
            : .textField(text.wrappedValue, prompt: prompt?.plain, isSecure: false)
        part = _field(title, kind, set: _textSetter(text))
    }

    public var _parts: [_Part] { [part] }
}

/// A text field that never shows what is typed.
public struct SecureField: _PrimitiveView {
    let part: _Part

    public init(_ title: String, text: Binding<String>, prompt: Text? = nil) {
        part = _field(title, .textField(text.wrappedValue, prompt: prompt?.plain, isSecure: true), set: _textSetter(text))
    }

    public var _parts: [_Part] { [part] }
}

/// Several lines of text.
public struct TextEditor: _PrimitiveView {
    let part: _Part

    public init(text: Binding<String>) {
        part = _field("", .textEditor(text.wrappedValue, prompt: nil), set: _textSetter(text))
    }

    /// With `title` in the form's label column.
    public init(_ title: String, text: Binding<String>) {
        part = _field(title, .textEditor(text.wrappedValue, prompt: nil), set: _textSetter(text))
    }

    public var _parts: [_Part] { [part] }
}

/// A checkbox.
public struct Toggle: _PrimitiveView {
    let part: _Part

    public init(_ title: String, isOn: Binding<Bool>) {
        part = _field(title, .toggle(title, isOn: isOn.wrappedValue)) { value in
            if case .bool(let flag) = value { isOn.wrappedValue = flag }
        }
    }

    public var _parts: [_Part] { [part] }
}

/// A picker's options, and what choosing one sets. The selection crosses as an index.
public final class _Picker {
    let title: String
    let options: [PluginOption]
    let selection: Int?
    let set: (Int?) -> Void

    init(title: String, options: [PluginOption], selection: Int?, set: @escaping (Int?) -> Void) {
        self.title = title
        self.options = options
        self.selection = selection
        self.set = set
    }
}

/// Each option's title, icon and section, with its tag, from a picker's content.
func _options(_ parts: [_Part]) -> (options: [PluginOption], tags: [AnyHashable?]) {
    var options: [PluginOption] = []
    var tags: [AnyHashable?] = []
    func add(_ part: _Part, section: String?) {
        options.append(PluginOption(title: part.plainTitle, icon: part.icon, section: section))
        tags.append(part.tag)
    }
    for part in parts {
        switch part.kind {
        case .section:
            for child in part.children { add(child, section: part.title.isEmpty ? nil : part.title) }
        case .row, .text, .button:
            add(part, section: nil)
        default:
            break
        }
    }
    return (options, tags)
}

/// One choice of several: each option's `.tag(_:)` (or `ForEach`'s identity) is what it sets.
/// In a `.toolbar` it sits beside the search field; in a `Form` it's a field.
public struct Picker: _PrimitiveView {
    let part: _Part

    public init<SelectionValue: Hashable, Content: View>(
        _ title: String, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content
    ) {
        let (options, tags) = _options(_resolve(content()))
        let current = AnyHashable(selection.wrappedValue)
        let picker = _Picker(title: title, options: options, selection: tags.firstIndex { $0 == current }) { index in
            guard let index, tags.indices.contains(index), let value = tags[index]?.base as? SelectionValue else {
                return
            }
            selection.wrappedValue = value
        }
        var made = _Part(.picker)
        made.title = title
        made.picker = picker
        part = made
    }

    public var _parts: [_Part] { [part] }
}

/// Any number of choices, drawn as chips.
public struct MultiPicker: _PrimitiveView {
    let part: _Part

    public init<SelectionValue: Hashable, Content: View>(
        _ title: String, selection: Binding<Set<SelectionValue>>, @ViewBuilder content: () -> Content
    ) {
        let (options, tags) = _options(_resolve(content()))
        var chosen: [Int] = []
        for (index, tag) in tags.enumerated() {
            if let value = tag?.base as? SelectionValue, selection.wrappedValue.contains(value) { chosen.append(index) }
        }
        part = _field(title, .multiPicker(options, selection: chosen)) { value in
            guard case .indices(let indices) = value else { return }
            var values = Set<SelectionValue>()
            for index in indices where tags.indices.contains(index) {
                if let value = tags[index]?.base as? SelectionValue { values.insert(value) }
            }
            selection.wrappedValue = values
        }
    }

    public var _parts: [_Part] { [part] }
}

/// Which parts of a date a `DatePicker` edits.
public struct DatePickerComponents: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let date = DatePickerComponents(rawValue: 1)
    public static let hourAndMinute = DatePickerComponents(rawValue: 2)
}

/// A date, typed as words ("tomorrow at 10am") or picked.
public struct DatePicker: _PrimitiveView {
    let part: _Part

    public init(
        _ title: String, selection: Binding<Date>, displayedComponents: DatePickerComponents = [.date, .hourAndMinute]
    ) {
        part = _field(
            title,
            .datePicker(
                selection.wrappedValue.timeIntervalSince1970,
                includesTime: displayedComponents.contains(.hourAndMinute))
        ) { value in
            if case .date(let seconds?) = value { selection.wrappedValue = Date(timeIntervalSince1970: seconds) }
        }
    }

    public var _parts: [_Part] { [part] }
}

/// Files or folders, chosen in an open panel.
public struct FilePicker: _PrimitiveView {
    let part: _Part

    public init(
        _ title: String, selection: Binding<[URL]>, allowsMultiple: Bool = true, choosesDirectories: Bool = false,
        choosesFiles: Bool = true
    ) {
        part = _field(
            title,
            .filePicker(
                selection.wrappedValue.map { $0.path }, allowsMultiple: allowsMultiple,
                choosesDirectories: choosesDirectories, choosesFiles: choosesFiles)
        ) { value in
            if case .paths(let paths) = value { selection.wrappedValue = paths.map { URL(fileURLWithPath: $0) } }
        }
    }

    public var _parts: [_Part] { [part] }
}
