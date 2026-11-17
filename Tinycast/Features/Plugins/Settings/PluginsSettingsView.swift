import SwiftUI

struct PluginsSettingsView: View {
    @Environment(AppCore.self) private var core

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
        .task(id: settings.pluginsEnabled) { await core.plugins.refresh() }
    }

    private var installed: some View {
        Section {
            if core.plugins.installed.isEmpty {
                Text("Put a plugin's folder in the Plugins folder and its commands appear in the launcher.")
                    .foregroundStyle(.secondary)
            }
            ForEach(core.plugins.installed) { plugin in
                PluginSettingsRow(plugin: plugin)
            }
            HStack {
                Button("Open Plugins Folder") { core.pluginCoordinator.revealPluginsFolder() }
                Spacer()
                Button("Reload") { Task { await core.plugins.refresh() } }
            }
        } header: {
            SettingsSectionHeader(.pluginsInstalled)
        }
    }
}

private struct PluginSettingsRow: View {
    let plugin: InstalledPlugin

    var body: some View {
        switch plugin.manifest {
        case .success(let manifest):
            SettingsRow(title: manifest.title, subtitle: summary(manifest), subtitleLineLimit: 2) {
                icon(manifest.icon ?? "puzzlepiece", tint: SettingsTab.plugins.tint)
            } trailing: {
                EmptyView()
            }
        case .failure(let error):
            SettingsRow(
                title: plugin.directory.lastPathComponent, subtitle: error.description,
                subtitleLineLimit: 2
            ) {
                icon("exclamationmark.triangle.fill", tint: .red)
            } trailing: {
                EmptyView()
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
