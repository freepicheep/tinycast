import AppKit
import SwiftUI

struct PluginsSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(SettingsNavigationState.self) private var navigation
    /// The open row's plugin name, which "Configure Plugin" navigates to.
    @State private var expanded: String?

    var body: some View {
        @Bindable var settings = core.settings
        return Form {
            Section {
                Toggle(
                    isOn: Binding(
                        get: { settings.pluginsEnabled },
                        // Enabling is consent to run third-party code, so the setter confirms.
                        set: { core.pluginCoordinator.setPluginsEnabled($0) })
                ) {
                    SettingsFeatureToggleLabel(
                        anchor: .pluginsPlugins, title: "Enable plugins",
                        subtitle: "Run commands written in Swift, each in its own sandbox.")
                }
            }
            .settingsAnchor(.pluginsPlugins)

            installed
                .settingsEnabled(settings.pluginsEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.plugins)
        // Listed from disk here; the main app runs them, and its set moving moves the revision.
        .task(id: settings.pluginsEnabled) { await core.plugins.list(settings.pluginsEnabled) }
        .onChange(of: core.mainApp?.status.plugins.revision) {
            Task { await core.plugins.list(core.settings.pluginsEnabled) }
        }
        .onChange(of: navigation.scrollRequest, initial: true) {
            if case .row(.pluginsInstalled, let name)? = navigation.scrollRequest?.target { expanded = name }
        }
    }

    private var installed: some View {
        Section {
            if core.plugins.installed.isEmpty {
                Text("Put a plugin's folder in the Plugins folder and its commands appear in the launcher.")
                    .foregroundStyle(.secondary)
            }
            ForEach(core.plugins.installed) { plugin in
                PluginSettingsRow(
                    plugin: plugin, isConfigurable: core.settings.pluginsEnabled,
                    status: core.mainApp?.status.plugins ?? MainAppStatus.Plugins(),
                    send: { core.mainApp?.send($0) }, expanded: $expanded,
                    onReveal: { NSWorkspace.shared.activateFileViewerSelecting([plugin.directory]) })
            }
            HStack {
                Button("Open Plugins Folder") { revealPluginsFolder() }
                Spacer()
                Button("Reload") {
                    core.mainApp?.send(.reloadPlugins)
                    Task { await core.plugins.list(core.settings.pluginsEnabled) }
                }
            }
        } header: {
            SettingsSectionHeader(.pluginsInstalled)
        }
    }

    private func revealPluginsFolder() {
        let directory = PluginCatalog.pluginsDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}

private struct PluginSettingsRow: View {
    let plugin: InstalledPlugin
    /// False while plugins are off: the main app keeps nothing for them to edit.
    let isConfigurable: Bool
    let status: MainAppStatus.Plugins
    let send: (SettingsAction) -> Void
    @Binding var expanded: String?
    let onReveal: () -> Void

    var body: some View {
        switch plugin.manifest {
        case .success(let manifest):
            let isExpanded = isConfigurable && expanded == manifest.name
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(title: manifest.title, subtitle: summary(manifest), subtitleLineLimit: 2) {
                    icon(manifest.icon ?? "puzzlepiece", tint: SettingsTab.plugins.tint)
                } trailing: {
                    // A plugin is a folder the user keeps: Tinycast shows it, and never deletes it.
                    Button(action: onReveal) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Show in Finder")
                    .accessibilityLabel("Show \(manifest.title) in Finder")
                    if isConfigurable {
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.rect)
                .onTapGesture {
                    guard isConfigurable else { return }
                    expanded = isExpanded ? nil : manifest.name
                }
                .accessibilityAddTraits(isConfigurable ? .isButton : [])
                if isExpanded {
                    PluginSettingsCard(manifest: manifest, directory: plugin.directory, status: status, send: send)
                        .padding(.top, Theme.Spacing.lg)
                }
            }
            .id(SettingsTarget.row(.pluginsInstalled, manifest.name))
        case .failure(let error):
            SettingsRow(
                title: plugin.directory.lastPathComponent, subtitle: error.description,
                subtitleLineLimit: 2
            ) {
                icon("exclamationmark.triangle.fill", tint: .red)
            } trailing: {
                Button(action: onReveal) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
            }
        }
    }

    /// A tile is a `GeometryReader`, so it takes the size it's given: a settings row's icon size.
    private func icon(_ symbol: String, tint: IconTint) -> some View {
        IconTile(symbol: symbol, tint: tint)
            .frame(width: Theme.Size.rowIcon, height: Theme.Size.rowIcon)
    }

    /// Up to three command titles, then how many more, so a big plugin's row stays readable.
    private func summary(_ manifest: PluginManifest) -> String {
        let titles = manifest.commands.map(\.title)
        let commands =
            titles.count <= 3
            ? titles.formatted(.list(type: .and))
            : String(localized: "\(titles.prefix(3).joined(separator: ", ")) and \(titles.count - 3) more")
        var parts = [commands]
        if !manifest.permissions.isEmpty {
            let granted = manifest.permissions.map(\.title).sorted().formatted(.list(type: .and))
            parts.append(String(localized: "Uses \(granted)"))
        }
        if !manifest.urlSchemes.isEmpty {
            let schemes = manifest.urlSchemes.sorted().formatted(.list(type: .and))
            parts.append(String(localized: "Opens \(schemes) links"))
        }
        return parts.joined(separator: " · ")
    }
}
