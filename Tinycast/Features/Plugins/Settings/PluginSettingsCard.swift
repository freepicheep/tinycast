import AppKit
import SwiftUI

/// One plugin's settings under its row: its preferences, then each command's alias, shortcut,
/// launcher visibility, and the background or menu-bar switch its kind has. Values come from the
/// main app's status, and edits go back to it, which owns the plugin's stored data.
struct PluginSettingsCard: View {
    let manifest: PluginManifest
    let directory: URL
    let status: MainAppStatus.Plugins
    let send: (SettingsAction) -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.lg, verticalSpacing: Theme.Spacing.md) {
            if !manifest.preferences.isEmpty {
                heading(String(localized: "Preferences"))
                ForEach(Array(manifest.preferences.enumerated()), id: \.element.name) { index, preference in
                    if index > 0 { rule }
                    PluginPreferenceRow(
                        plugin: manifest.name, preference: preference,
                        value: status.preferences[manifest.name]?[preference.name], send: send)
                }
                rule
            }
            heading(
                manifest.commands.count == 1 ? String(localized: "Command") : String(localized: "Commands"))
            ForEach(Array(manifest.commands.enumerated()), id: \.element.id) { index, command in
                if index > 0 { rule }
                PluginCommandRows(
                    manifest: manifest, directory: directory, command: command, status: status, send: send)
            }
            if status.signedIn.contains(manifest.name) {
                rule
                PluginCardRow(
                    title: String(localized: "Signed in"),
                    detail: String(localized: "Signing out forgets the plugin's tokens.")
                ) {
                    Button("Sign Out") { send(.signOutPlugin(manifest.name)) }
                }
            }
        }
        // Indented under the row's icon, so the settings read as belonging to the row above them.
        .padding(.leading, Theme.Size.rowIcon + Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heading(_ title: String) -> some View {
        GridRow {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
                .gridCellColumns(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Theme.Spacing.xs)
        }
    }

    private var rule: some View {
        GridRow { Divider().gridCellColumns(2) }
    }
}

private struct PluginCardRow<Control: View>: View {
    /// Wide enough for a path field, and the trailing edge every control in the column shares.
    static var controlWidth: CGFloat { 200 }

    let title: String
    var detail: String?
    var indent: CGFloat = 0
    var badge: String?
    var controlWidth: CGFloat? = Self.controlWidth
    @ViewBuilder var control: Control

    var body: some View {
        GridRow(alignment: .center) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(title)
                    if let badge {
                        Text(badge)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Theme.Spacing.xs)
                            .padding(.vertical, 1)
                            .background(Theme.Colors.controlSurface, in: .capsule)
                    }
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, indent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .gridColumnAlignment(.leading)
            control
                .frame(width: controlWidth, alignment: .trailing)
                .gridColumnAlignment(.trailing)
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }
}

private struct PluginCommandRows: View {
    let manifest: PluginManifest
    let directory: URL
    let command: PluginCommand
    let status: MainAppStatus.Plugins
    let send: (SettingsAction) -> Void
    @Environment(VisibilityStore.self) private var visibility

    private var ref: PluginCommandRef { PluginCommandRef(plugin: manifest.name, command: command.name) }

    private var entry: AppEntry {
        AppEntry(
            id: ref.entryID, name: command.title, url: directory, bundleID: nil, kind: .pluginCommand,
            ownerName: manifest.title)
    }

    private var badge: String? {
        switch command.mode {
        case .view: nil
        case .action: String(localized: "Action")
        case .menuBar: String(localized: "Menu Bar")
        }
    }

    private var settings: PluginStore.CommandSettings {
        status.commands[ref.entryID] ?? PluginStore.CommandSettings()
    }

    var body: some View {
        let entry = entry
        let isVisible = visibility.isItemVisible(entry)
        PluginCardRow(title: command.title, detail: command.description, badge: badge, controlWidth: nil) {
            HStack(spacing: Theme.Spacing.lg) {
                AliasField(entry: entry).settingsEnabled(isVisible)
                ShortcutRecorder(action: .pluginCommand(entryID: entry.id))
                Toggle("", isOn: Binding(get: { isVisible }, set: { visibility.setItemVisible($0, for: entry) }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help("Show in launcher")
                    .accessibilityLabel("Show \(command.title) in launcher")
            }
        }
        if command.mode == .menuBar {
            PluginCardRow(title: String(localized: "Show in menu bar"), indent: Theme.Spacing.lg) {
                Toggle(
                    "Show in menu bar",
                    isOn: Binding(
                        get: { settings.showsInMenuBar ?? true }, set: { send(.setPluginMenuBar(ref, $0)) })
                )
                .labelsHidden()
            }
        }
        if command.mode == .action, let interval = command.interval {
            PluginCardRow(
                title: String(localized: "Run in the background"), detail: detail(interval),
                indent: Theme.Spacing.lg
            ) {
                Toggle(
                    "Run in the background",
                    isOn: Binding(
                        get: { settings.runsInBackground ?? true }, set: { send(.setPluginBackground(ref, $0)) })
                )
                .labelsHidden()
            }
        }
        ForEach(command.preferences, id: \.name) { preference in
            PluginPreferenceRow(
                plugin: manifest.name, preference: preference,
                value: status.preferences[manifest.name]?[preference.name], send: send, indent: Theme.Spacing.lg)
        }
    }

    private func detail(_ interval: TimeInterval) -> String {
        let every = Duration.seconds(interval).formatted(.units(allowed: [.days, .hours, .minutes, .seconds]))
        var detail = String(localized: "Every \(every).")
        if let lastRun = settings.lastRun {
            detail += " " + String(localized: "Last run \(lastRun.formatted(.relative(presentation: .named))).")
        } else {
            detail += " " + String(localized: "Hasn't run yet.")
        }
        return detail
    }
}

private struct PluginPreferenceRow: View {
    let plugin: String
    let preference: PluginPreference
    let value: PluginValue?
    let send: (SettingsAction) -> Void
    var indent: CGFloat = 0
    @State private var text = ""
    @State private var flag = false
    @State private var loaded = false

    var body: some View {
        PluginCardRow(title: preference.title, detail: detail, indent: indent) {
            control
        }
        .onAppear(perform: load)
    }

    private var detail: String? {
        let description = preference.description ?? ""
        guard preference.required == true else { return description }
        let requirement = String(localized: "Required.")
        return description.isEmpty ? requirement : description + " " + requirement
    }

    @ViewBuilder
    private var control: some View {
        switch preference.type {
        case "checkbox":
            Toggle(preference.label ?? "", isOn: $flag)
                .labelsHidden()
                .onChange(of: flag) { _, flag in save(.bool(flag)) }
        case "dropdown":
            Picker("", selection: $text) {
                ForEach(preference.data ?? [], id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            }
            .labelsHidden()
            .onChange(of: text) { _, text in save(.string(text)) }
        case "password":
            SecureField("", text: $text, prompt: preference.placeholder.map(Text.init))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onChange(of: text) { _, text in save(.string(text)) }
        case "file", "directory", "appPicker":
            HStack(spacing: Theme.Spacing.sm) {
                Text(text.isEmpty ? String(localized: "Not set") : (text as NSString).lastPathComponent)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…", action: choosePath)
            }
        default:
            TextField("", text: $text, prompt: preference.placeholder.map(Text.init))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onChange(of: text) { _, text in save(.string(text)) }
        }
    }

    /// Read once: the status echoes each edit back, and a field mid-typing mustn't jump.
    private func load() {
        let current = value ?? preference.defaultValue
        if case .string(let string)? = current { text = string }
        if case .bool(let bool)? = current { flag = bool }
        loaded = true
    }

    private func save(_ new: PluginValue) {
        guard loaded else { return }
        send(.setPluginPreference(plugin, key: preference.name, new))
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = preference.type != "directory"
        panel.canChooseDirectories = preference.type == "directory"
        if preference.type == "appPicker" {
            panel.directoryURL = URL(filePath: "/Applications")
            panel.allowedContentTypes = [.application]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        text = url.path
        save(.string(url.path))
    }
}
