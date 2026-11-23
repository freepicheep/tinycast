import AppKit

/// Plugins' switch and folder; their commands run in the Extensions host like any other.
@MainActor
final class PluginCoordinator {
    private let plugins: PluginManager
    private let paletteCoordinator: PaletteCoordinator
    private let settingsCoordinator: SettingsCoordinator
    private let settings: AppSettings
    /// Dialogs and HUDs only — never for state this type owns.
    private unowned let core: AppCore

    init(
        plugins: PluginManager, paletteCoordinator: PaletteCoordinator,
        settingsCoordinator: SettingsCoordinator, settings: AppSettings, core: AppCore
    ) {
        self.plugins = plugins
        self.paletteCoordinator = paletteCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.settings = settings
        self.core = core
    }

    func start(extensions: ExtensionManager) {
        plugins.start(extensions: extensions)
    }

    // MARK: - Feature presence

    func applyEnabled() {
        Task { await plugins.setEnabled(settings.pluginsEnabled) }
    }

    /// Also consent to run code someone else wrote, so it asks; the switch's track starts them.
    func setPluginsEnabled(_ enabled: Bool) {
        guard enabled != settings.pluginsEnabled else { return }
        guard enabled else {
            settings.pluginsEnabled = false
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        Task {
            guard
                await core.confirm(
                    title: String(localized: "Enable plugins?"),
                    message: String(
                        localized: """
                            Plugins are Swift scripts that run inside Tinycast. Each one sees only \
                            what Tinycast gives it — its own screen and storage, and the network or \
                            clipboard only if it asks for them — and stops if it runs too long.
                            """),
                    symbol: SettingsTab.plugins.systemImage, confirmTitle: String(localized: "Enable"),
                    tone: .neutral, confirmRole: .standard)
            else { return }
            settings.pluginsEnabled = true
        }
    }

    func showPluginSettings() {
        paletteCoordinator.hidePalette(restoreFocus: false)
        settingsCoordinator.showSettings(tab: .plugins)
    }
}
