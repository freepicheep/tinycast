import AppKit
import SwiftUI

/// The plugin owns a form's values: each edit is sent back and the next frame draws it. A text
/// field keeps its own draft while it has focus, so a frame for an older keystroke can't undo a
/// newer one.
struct PluginFormView: View {
    @Environment(\.metrics) private var metrics
    @Environment(PaletteState.self) private var palette
    let form: PluginFormScreen
    let layout: PluginScreenLayout
    /// The focused field, as the palette's flat index.
    let selection: Int
    let scroll: ScrollIntent
    let onSelect: (Int) -> Void
    let onSet: (String, PluginFieldValue) -> Void
    let onSubmit: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: metrics.spacing.xl) {
                    ForEach(form.fields) { field in
                        row(field)
                    }
                }
                .font(metrics.typography.rowTitle)
                .foregroundStyle(Theme.Colors.textPrimary)
                .padding(.horizontal, metrics.spacing.xxxl)
                .padding(.vertical, metrics.spacing.lg)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .focusEffectDisabled()
            .scrollFollowsSelection(scroll, row: selectedID, atOrigin: selection == 0, proxy: proxy)
        }
        .onAppear { noteEditing() }
        .onChange(of: selection) { noteEditing() }
        .onDisappear { palette.noteEditingField(false) }
    }

    private var selectedID: String? {
        layout.items.indices.contains(selection) ? layout.items[selection].id : nil
    }

    /// A text control owns the keyboard, so a bare ⌫ edits instead of backing out of the command.
    private func noteEditing() {
        let field = layout.items.indices.contains(selection) ? layout.items[selection].field : nil
        switch field?.kind {
        case .textField?, .textEditor?: palette.noteEditingField(true)
        default: palette.noteEditingField(false)
        }
    }

    private func index(of field: PluginField) -> Int? {
        layout.items.first { $0.id == field.id }?.index
    }

    private func focus(_ index: Int) -> Binding<Bool> {
        Binding(get: { selection == index }, set: { if $0, selection != index { onSelect(index) } })
    }

    private func moveFocus(from index: Int) -> (Bool) -> Void {
        { backwards in
            let count = layout.items.count
            guard count > 0 else { return }
            onSelect((index + (backwards ? -1 : 1) + count) % count)
        }
    }

    @ViewBuilder
    private func row(_ field: PluginField) -> some View {
        if let index = index(of: field) {
            labelled(field) { control(field, index: index) }
                .id(field.id)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { if selection != index { onSelect(index) } })
        } else {
            switch field.kind {
            case .separator:
                Rectangle().fill(Theme.Colors.separator).frame(height: 1)
            case .text(let text):
                labelled(field) {
                    Text(text)
                        .font(metrics.typography.rowTrailing)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            default:
                EmptyView()
            }
        }
    }

    private func labelled(_ field: PluginField, @ViewBuilder content: () -> some View) -> some View {
        let labelWidth = (metrics.size.panelWidth * 0.16).rounded()
        return HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.xxl) {
            Text(field.title ?? "")
                .font(metrics.typography.sectionHeader)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(width: labelWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: metrics.spacing.xs) {
                content()
                if let error = field.error, !error.isEmpty {
                    Text(error)
                        .font(metrics.typography.rowTrailing)
                        .foregroundStyle(Theme.Colors.destructive)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(field.info ?? "")
            Color.clear.frame(width: labelWidth, height: 0)
        }
    }

    @ViewBuilder
    private func control(_ field: PluginField, index: Int) -> some View {
        let selected = selection == index
        switch field.kind {
        case .textField(let value, let prompt, let isSecure):
            PluginTextInput(
                value: value, prompt: prompt, label: field.title ?? field.id, isSecure: isSecure,
                multiline: false, focused: focus(index), moveFocus: moveFocus(from: index),
                onChange: { onSet(field.id, .text($0)) })
        case .textEditor(let value, let prompt):
            PluginTextInput(
                value: value, prompt: prompt, label: field.title ?? field.id, isSecure: false, multiline: true,
                focused: focus(index), moveFocus: moveFocus(from: index),
                onChange: { onSet(field.id, .text($0)) })
        case .toggle(let label, let isOn):
            Toggle(label, isOn: Binding(get: { isOn }, set: { onSet(field.id, .bool($0)) }))
                .toggleStyle(.checkbox)
                .padding(.vertical, metrics.spacing.xs)
                .padding(.horizontal, metrics.spacing.sm)
                .formFieldChrome(focused: selected)
                .onKeyPress(.space) {
                    guard selected else { return .ignored }
                    onSet(field.id, .bool(!isOn))
                    return .handled
                }
        case .picker(let picker):
            Picker(
                field.title ?? "",
                selection: Binding(get: { picker.selection ?? -1 }, set: { onSet(field.id, .index($0)) })
            ) {
                if picker.selection == nil { Text("Select…").tag(-1) }
                ForEach(Array(picker.options.enumerated()), id: \.offset) { offset, option in
                    Text(option.title).tag(offset)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .formFieldChrome(focused: selected)
        case .multiPicker(let options, let chosen):
            Menu {
                ForEach(Array(options.enumerated()), id: \.offset) { offset, option in
                    Toggle(
                        option.title,
                        isOn: Binding(
                            get: { chosen.contains(offset) },
                            set: { on in
                                let next = on ? (chosen + [offset]).sorted() : chosen.filter { $0 != offset }
                                onSet(field.id, .indices(next))
                            }))
                }
            } label: {
                Text(
                    chosen.isEmpty
                        ? String(localized: "Select…")
                        : chosen.compactMap { options.indices.contains($0) ? options[$0].title : nil }
                            .formatted(.list(type: .and)))
            }
            .menuStyle(.borderlessButton)
            .padding(.vertical, metrics.spacing.xs)
            .padding(.horizontal, metrics.spacing.sm)
            .formFieldChrome(focused: selected)
        case .datePicker(let seconds, let includesTime):
            PluginDateInput(
                seconds: seconds, includesTime: includesTime, selected: selected,
                onChange: { onSet(field.id, .date($0)) })
        case .filePicker(let paths, let allowsMultiple, let choosesDirectories, let choosesFiles):
            PluginFileInput(
                paths: paths, allowsMultiple: allowsMultiple, choosesDirectories: choosesDirectories,
                choosesFiles: choosesFiles, selected: selected, onChange: { onSet(field.id, .paths($0)) })
        case .text, .separator, .unsupported:
            EmptyView()
        }
    }
}

/// A text field or editor with the draft it keeps while focused.
private struct PluginTextInput: View {
    @Environment(\.metrics) private var metrics
    let value: String
    let prompt: String?
    let label: String
    let isSecure: Bool
    let multiline: Bool
    @Binding var focused: Bool
    let moveFocus: (Bool) -> Void
    let onChange: (String) -> Void
    @State private var draft: String?
    @State private var textSelection: TextSelection?

    private var text: Binding<String> {
        Binding(
            get: { draft ?? value },
            set: { new in
                guard new != (draft ?? value) else { return }
                draft = new
                onChange(new)
            })
    }

    var body: some View {
        Group {
            if multiline {
                FormTextArea(
                    text: text, selection: $textSelection, focused: $focused, minimumHeight: 80, label: label,
                    moveFocus: moveFocus)
            } else if isSecure {
                SecureField(prompt ?? "", text: text)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, metrics.spacing.sm)
                    .frame(height: metrics.size.dialogButtonHeight)
            } else {
                FormTextInput(
                    text: text, focused: $focused, placeholder: prompt ?? "", label: label, moveFocus: moveFocus
                )
                .frame(height: metrics.size.dialogButtonHeight)
            }
        }
        .formFieldChrome(focused: focused)
        // Leaving the field hands it back to the plugin's value.
        .onChange(of: focused) { _, isFocused in
            if !isFocused { draft = nil }
        }
    }
}

private struct PluginDateInput: View {
    @Environment(\.metrics) private var metrics
    let seconds: Double?
    let includesTime: Bool
    let selected: Bool
    let onChange: (Double?) -> Void

    var body: some View {
        HStack(spacing: metrics.spacing.sm) {
            if let seconds {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { Date(timeIntervalSince1970: seconds) },
                        set: { onChange($0.timeIntervalSince1970) }),
                    displayedComponents: includesTime ? [.date, .hourAndMinute] : [.date]
                )
                .labelsHidden()
                .datePickerStyle(.field)
                Button(String(localized: "Clear")) { onChange(nil) }
                    .buttonStyle(.link)
            } else {
                Button(String(localized: "Choose a Date")) { onChange(Date().timeIntervalSince1970) }
                    .buttonStyle(.link)
            }
        }
        .padding(.vertical, metrics.spacing.xs)
        .padding(.horizontal, metrics.spacing.sm)
        .formFieldChrome(focused: selected)
    }
}

private struct PluginFileInput: View {
    @Environment(\.metrics) private var metrics
    let paths: [String]
    let allowsMultiple: Bool
    let choosesDirectories: Bool
    let choosesFiles: Bool
    let selected: Bool
    let onChange: ([String]) -> Void

    var body: some View {
        HStack(spacing: metrics.spacing.sm) {
            Text(
                paths.isEmpty
                    ? String(localized: "No selection")
                    : paths.map { ($0 as NSString).lastPathComponent }.formatted(.list(type: .and))
            )
            .foregroundStyle(paths.isEmpty ? Theme.Colors.textSecondary : Theme.Colors.textPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: metrics.spacing.sm)
            Button(String(localized: "Choose…"), action: choose)
                .buttonStyle(.link)
        }
        .padding(.vertical, metrics.spacing.xs)
        .padding(.horizontal, metrics.spacing.sm)
        .formFieldChrome(focused: selected)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = allowsMultiple
        panel.canChooseDirectories = choosesDirectories
        panel.canChooseFiles = choosesFiles
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        onChange(panel.urls.map(\.path))
    }
}
