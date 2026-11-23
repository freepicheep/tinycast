import AppKit
import SwiftUI

struct PluginsSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(ExtensionLibrary.self) private var library
    @Environment(SettingsNavigationState.self) private var navigation
    /// The open row's host name (`plugin.<name>`), which "Configure Plugin" navigates to.
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
        .onChange(of: library.catalogRevision) {
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
                    plugin: plugin, hosted: hosted(plugin), expanded: $expanded,
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

    /// The plugin as the Extensions host runs it, whose settings the row's card edits.
    private func hosted(_ plugin: InstalledPlugin) -> InstalledExtension? {
        guard core.settings.pluginsEnabled, case .success(let manifest) = plugin.manifest else { return nil }
        return core.plugins.hostExtensions().first { $0.manifest.name == manifest.hostName }
    }

    private func revealPluginsFolder() {
        let directory = PluginCatalog.pluginsDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}

private struct PluginSettingsRow: View {
    let plugin: InstalledPlugin
    /// Nil while plugins are off, or for a plugin whose manifest failed.
    let hosted: InstalledExtension?
    @Binding var expanded: String?
    let onReveal: () -> Void

    var body: some View {
        switch plugin.manifest {
        case .success(let manifest):
            let isExpanded = hosted != nil && expanded == manifest.hostName
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
                    if hosted != nil {
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.rect)
                .onTapGesture {
                    guard hosted != nil else { return }
                    expanded = isExpanded ? nil : manifest.hostName
                }
                .accessibilityAddTraits(hosted == nil ? [] : .isButton)
                if isExpanded, let hosted {
                    ExtensionSettingsCard(installed: hosted)
                        .padding(.top, Theme.Spacing.lg)
                }
            }
            .id(SettingsTarget.row(.pluginsInstalled, manifest.hostName))
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

    /// A tile is a `GeometryReader`, so it takes the size it's given: an extension's row icon size.
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
