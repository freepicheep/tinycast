import AppKit

/// How a plugin command meets the palette, and every host call that touches a surface.
@MainActor
final class PluginCoordinator: PluginHostServices {
    private let plugins: PluginManager
    private let palette: PaletteState
    private let paletteCoordinator: PaletteCoordinator
    private let settingsCoordinator: SettingsCoordinator
    private let settings: AppSettings
    /// Dialogs and HUDs only — never for state this type owns.
    private unowned let core: AppCore

    init(
        plugins: PluginManager, palette: PaletteState, paletteCoordinator: PaletteCoordinator,
        settingsCoordinator: SettingsCoordinator, settings: AppSettings, core: AppCore
    ) {
        self.plugins = plugins
        self.palette = palette
        self.paletteCoordinator = paletteCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.settings = settings
        self.core = core
    }

    func start(appIndex: AppIndex) {
        plugins.start(appIndex: appIndex, services: self)
        plugins.onFinish = { [weak self] in
            guard let self, self.palette.mode == .pluginCommand else { return }
            self.paletteCoordinator.hidePalette(restoreFocus: false)
        }
    }

    // MARK: - Feature presence

    func applyEnabled() {
        Task { await plugins.setEnabled(settings.pluginsEnabled) }
    }

    /// Also consent to run code someone else wrote, so it asks before it starts.
    func setPluginsEnabled(_ enabled: Bool) {
        guard enabled != settings.pluginsEnabled else { return }
        guard enabled else {
            settings.pluginsEnabled = false
            Task { await plugins.setEnabled(false) }
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
            await plugins.setEnabled(true)
        }
    }

    // MARK: - Running

    /// A view command takes over the palette; an action command closes it and runs.
    func run(entryID: String) {
        guard settings.pluginsEnabled, let (_, _, command) = plugins.resolve(entryID: entryID) else {
            return
        }
        switch command.mode {
        case .view:
            paletteCoordinator.navigate(to: .pluginCommand)
            if !paletteCoordinator.isVisible { paletteCoordinator.showPalette(mode: .pluginCommand) }
        case .action:
            paletteCoordinator.hidePalette(restoreFocus: false)
        }
        Task { await plugins.run(entryID: entryID) }
    }

    /// Escape past an empty search field: the plugin's own stack first, then the command.
    func exitPluginScreen() {
        if plugins.goBack() { return }
        plugins.stop()
        if !palette.pop() { paletteCoordinator.hidePalette() }
    }

    func revealPluginsFolder() {
        let directory = PluginCatalog.pluginsDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        paletteCoordinator.hidePalette(restoreFocus: false)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func showPluginSettings() {
        paletteCoordinator.hidePalette(restoreFocus: false)
        settingsCoordinator.showSettings(tab: .plugins)
    }

    // MARK: - PluginHostServices

    func showHUD(_ text: String) {
        core.showMessage(text)
    }

    func closeWindow() {
        paletteCoordinator.hidePalette(restoreFocus: false)
    }

    func copy(_ text: String) {
        Paster.copyPlainText(text)
        core.showMessage(String(localized: "Copied to Clipboard"))
    }

    func paste(_ text: String) {
        let target = paletteCoordinator.targetApp
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.pasteString(text, previousApp: target)
    }

    /// Already allowed by `PluginOpenTarget`; an app link with no app to take it says so.
    func open(_ url: URL) {
        if !url.isFileURL, NSWorkspace.shared.urlForApplication(toOpen: url) == nil {
            core.showMessage(
                String(localized: "No app on this Mac opens \(url.scheme ?? "") links"), tone: .danger)
            return
        }
        paletteCoordinator.hidePalette(restoreFocus: false)
        NSWorkspace.shared.open(url)
    }

    func refuseOpen(_ target: String) {
        let scheme = URL(string: target)?.scheme ?? target
        core.showMessage(
            String(localized: "This plugin can't open \(scheme) links: Manifest.swift doesn't list them"),
            tone: .danger)
    }
}
