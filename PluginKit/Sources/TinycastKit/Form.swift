// Forms: fields bound to a command's state, drawn as the palette's form rows.

import FoundationEssentials

/// A screen of fields. Each field's value is a `Binding`, so the form reads and writes the
/// command's own `@State`; `SubmitButton` in its actions saves the fields marked `storeValue`.
public struct Form: _PrimitiveView {
    var props: [String: PluginValue] = [:]
    let fields: [PluginNode]
    var task: _Task?

    public init<Content: View>(@ViewBuilder content: () -> Content) {
        fields = _nodes(content()).map { node in
            var node = node
            if node.type == "Separator" { node.type = "Form.Separator" }
            return node
        }
    }

    public var _elements: [_Element] { [.screen(_node("Form", props, children: fields), task)] }

    public func navigationTitle(_ title: String) -> Form { with("navigationTitle", .string(title)) }
    public func loading(_ isLoading: Bool) -> Form { with("isLoading", .bool(isLoading)) }

    /// ⌘↵ runs the first; usually a `SubmitButton`.
    public func actions(@ActionBuilder _ content: () -> [PluginNode]) -> Form {
        with("actions", .node(_actionPanel(content())))
    }

    public func task(_ action: @escaping () async -> Void) -> Form {
        var copy = self
        copy.task = _Task(key: "", run: action)
        return copy
    }

    func with(_ name: String, _ value: PluginValue) -> Form {
        var copy = self
        copy.props[name] = value
        return copy
    }
}

/// What every field shares: its component, and how its value is saved and restored.
public struct _FieldCore {
    var type: String
    var props: [String: PluginValue]
    /// The value as stored text, for `storeValue`.
    let stored: () -> String
    let restore: (String) -> Void
    /// The value as the field draws it, read after a stored value is restored.
    let value: () -> PluginValue
    var storesValue = false
    /// A picker's choices.
    var children: [PluginNode] = []

    var id: String {
        if case .string(let id) = props["id"] { return id }
        if case .string(let title) = props["title"] { return title }
        return type
    }

    var elements: [_Element] {
        var props = props
        if props["id"] == nil { props["id"] = .string(id) }
        if storesValue {
            let id = id
            let stored = stored
            _formFields[id] = stored
            if let entry = _rendering, !entry.restoredFields.contains(id) {
                entry.restoredFields.insert(id)
                if let saved = _environment?.storedFormValue(id) { restore(saved) }
            }
        }
        props["value"] = value()
        return [.node(_node(type, key: id, props, children: children))]
    }
}

/// The modifiers every field takes.
public protocol _FormField: _PrimitiveView {
    var _core: _FieldCore { get set }
}

extension _FormField {
    public var _elements: [_Element] { _core.elements }

    /// What the field's value is called in a stored value and a submitted form; its title otherwise.
    public func id(_ id: String) -> Self { setting("id", .string(id)) }

    /// A note beside the field.
    public func info(_ text: String) -> Self { setting("info", .string(text)) }

    /// A problem with the value, drawn under the field; nil clears it.
    public func error(_ message: String?) -> Self {
        setting("error", message.map { PluginValue.string($0) } ?? .null)
    }

    /// Where the form's focus starts.
    public func autoFocus() -> Self { setting("autoFocus", .bool(true)) }

    /// Saved when a `SubmitButton` runs, and the field starts from it the next time.
    public func storeValue() -> Self {
        var copy = self
        copy._core.storesValue = true
        return copy
    }

    func setting(_ name: String, _ value: PluginValue) -> Self {
        var copy = self
        copy._core.props[name] = value
        return copy
    }
}

/// The `storeValue` fields of the screen rendered last, by id.
var _formFields: [String: () -> String] = [:]

func _storeFormValues() {
    var values: [String: String] = [:]
    for (id, stored) in _formFields { values[id] = stored() }
    _environment?.storeFormValues(values)
}

func _change(_ body: @escaping (PluginValue?) -> Void) -> PluginValue {
    _handler { body($0.first) }
}

public struct TextField: _FormField {
    public var _core: _FieldCore

    public init(_ title: String, text: Binding<String>, prompt: String? = nil) {
        _core = _FieldCore(
            type: "Form.TextField",
            props: [
                "title": .string(title),
                "onTinycastChange": _change { text.wrappedValue = $0?.text ?? "" }
            ], stored: { text.wrappedValue }, restore: { text.wrappedValue = $0 },
            value: { .string(text.wrappedValue) })
        if let prompt { _core.props["placeholder"] = .string(prompt) }
    }
}

/// A text field that never shows what is typed.
public struct SecureField: _FormField {
    public var _core: _FieldCore

    public init(_ title: String, text: Binding<String>, prompt: String? = nil) {
        _core = _FieldCore(
            type: "Form.PasswordField",
            props: [
                "title": .string(title),
                "onTinycastChange": _change { text.wrappedValue = $0?.text ?? "" }
            ], stored: { text.wrappedValue }, restore: { text.wrappedValue = $0 },
            value: { .string(text.wrappedValue) })
        if let prompt { _core.props["placeholder"] = .string(prompt) }
    }
}

/// Several lines of text.
public struct TextEditor: _FormField {
    public var _core: _FieldCore

    public init(_ title: String, text: Binding<String>, prompt: String? = nil) {
        _core = _FieldCore(
            type: "Form.TextArea",
            props: [
                "title": .string(title),
                "onTinycastChange": _change { text.wrappedValue = $0?.text ?? "" }
            ], stored: { text.wrappedValue }, restore: { text.wrappedValue = $0 },
            value: { .string(text.wrappedValue) })
        if let prompt { _core.props["placeholder"] = .string(prompt) }
    }
}

/// A checkbox: `label` beside it, and `title` in the form's label column.
public struct Toggle: _FormField {
    public var _core: _FieldCore

    public init(_ label: String, title: String? = nil, isOn: Binding<Bool>) {
        _core = _FieldCore(
            type: "Form.Checkbox",
            props: [
                "label": .string(label),
                "onTinycastChange": _change { value in
                    if case .bool(let flag) = value { isOn.wrappedValue = flag }
                }
            ], stored: { isOn.wrappedValue ? "true" : "false" }, restore: { isOn.wrappedValue = $0 == "true" },
            value: { .bool(isOn.wrappedValue) })
        _core.props["title"] = .string(title ?? label)
    }
}

/// One choice of several, by value.
public struct Picker: _FormField {
    public var _core: _FieldCore

    public init(_ title: String, selection: Binding<String>, @DropdownBuilder _ choices: () -> [PluginNode]) {
        let retyped = choices().map { choice -> PluginNode in
            var choice = choice
            choice.type = "Form.Dropdown." + choice.type
            choice.children = choice.children.map { child in
                var child = child
                child.type = "Form.Dropdown." + child.type
                return child
            }
            return choice
        }
        _core = _FieldCore(
            type: "Form.Dropdown",
            props: [
                "title": .string(title),
                "onTinycastChange": _change { selection.wrappedValue = $0?.text ?? "" }
            ], stored: { selection.wrappedValue }, restore: { selection.wrappedValue = $0 },
            value: { .string(selection.wrappedValue) })
        _core.children = retyped
    }
}

/// Any number of choices, drawn as chips.
public struct TagPicker: _FormField {
    public var _core: _FieldCore

    public init(_ title: String, selection: Binding<[String]>, @DropdownBuilder _ choices: () -> [PluginNode]) {
        let retyped = choices().map { choice -> PluginNode in
            var choice = choice
            choice.type = "Form.TagPicker.Item"
            return choice
        }
        _core = _FieldCore(
            type: "Form.TagPicker",
            props: [
                "title": .string(title),
                "onTinycastChange": _change { value in selection.wrappedValue = _strings(value) }
            ], stored: { selection.wrappedValue.joined(separator: "\n") },
            restore: { selection.wrappedValue = $0.isEmpty ? [] : $0.split(separator: "\n").map { String($0) } },
            value: { .array(selection.wrappedValue.map { PluginValue.string($0) }) })
        _core.children = retyped
    }
}

/// A date, typed as words ("tomorrow at 10am") or picked.
public struct DatePicker: _FormField {
    public var _core: _FieldCore

    public init(_ title: String, selection: Binding<Date?>, includesTime: Bool = true) {
        _core = _FieldCore(
            type: "Form.DatePicker",
            props: [
                "title": .string(title), "type": .string(includesTime ? "date_time" : "date"),
                "onTinycastChange": _change { value in
                    if case .date(let seconds) = value {
                        selection.wrappedValue = Date(timeIntervalSince1970: seconds)
                    } else {
                        selection.wrappedValue = nil
                    }
                }
            ],
            stored: { selection.wrappedValue.map { String($0.timeIntervalSince1970) } ?? "" },
            restore: { selection.wrappedValue = Double($0).map { Date(timeIntervalSince1970: $0) } },
            value: { selection.wrappedValue.map { PluginValue.date($0.timeIntervalSince1970) } ?? .null })
    }
}

/// Files or folders, chosen in an open panel, as paths.
public struct FilePicker: _FormField {
    public var _core: _FieldCore

    public init(
        _ title: String, selection: Binding<[String]>, allowsMultiple: Bool = true,
        choosesDirectories: Bool = false, choosesFiles: Bool = true
    ) {
        _core = _FieldCore(
            type: "Form.FilePicker",
            props: [
                "title": .string(title),
                "allowMultipleSelection": .bool(allowsMultiple),
                "canChooseDirectories": .bool(choosesDirectories), "canChooseFiles": .bool(choosesFiles),
                "onTinycastChange": _change { value in selection.wrappedValue = _strings(value) }
            ], stored: { selection.wrappedValue.joined(separator: "\n") },
            restore: { selection.wrappedValue = $0.isEmpty ? [] : $0.split(separator: "\n").map { String($0) } },
            value: { .array(selection.wrappedValue.map { PluginValue.string($0) }) })
    }
}

/// A line of text in a form, with an optional title in the label column.
public struct Text: _PrimitiveView {
    let props: [String: PluginValue]

    public init(_ text: String, title: String? = nil) {
        var props: [String: PluginValue] = ["text": .string(text)]
        if let title { props["title"] = .string(title) }
        self.props = props
    }

    public var _elements: [_Element] { [.node(_node("Form.Description", props))] }
}

func _strings(_ value: PluginValue?) -> [String] {
    guard case .array(let values) = value else { return [] }
    return values.compactMap { $0.text }
}
