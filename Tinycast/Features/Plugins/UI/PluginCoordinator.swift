import AppKit

/// How plugin commands meet the app: the Plugins switch, launching from the launcher, a shortcut or
/// a link, leaving the palette's command screen, and the window work a running command asks for.
@MainActor
final class PluginCoordinator {
    private let plugins: PluginManager
    private let host: PluginHost
    private let palette: PaletteState
    private let paletteCoordinator: PaletteCoordinator
    private let settingsCoordinator: SettingsCoordinator
    private let settings: AppSettings
    /// Dialogs and HUDs only — never for state this type owns.
    private unowned let core: AppCore

    init(
        plugins: PluginManager, host: PluginHost, palette: PaletteState, paletteCoordinator: PaletteCoordinator,
        settingsCoordinator: SettingsCoordinator, settings: AppSettings, core: AppCore
    ) {
        self.plugins = plugins
        self.host = host
        self.palette = palette
        self.paletteCoordinator = paletteCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.settings = settings
        self.core = core
    }

    func start(appIndex: AppIndex) {
        host.start(appIndex: appIndex, coordinator: self)
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

    func showSettings(for plugin: String) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        settingsCoordinator.showSettings(tab: .plugins, revealing: .row(.pluginsInstalled, plugin))
    }

    // MARK: - Launching

    /// From a shortcut: resolved from the installed set, since the launcher may never have opened.
    func runPluginCommand(entryID: String) {
        guard settings.pluginsEnabled, let ref = PluginCommandRef(entryID: entryID) else { return }
        // The shortcut's second press closes its command, as a mode command's does.
        if paletteCoordinator.isShowing(.pluginCommand), host.running == ref {
            paletteCoordinator.hidePalette()
            return
        }
        run(ref)
    }

    func runPluginCommand(_ app: AppEntry, arguments: [String: String] = [:]) {
        guard let ref = PluginCommandRef(entryID: app.id) else { return }
        run(ref, arguments: arguments)
    }

    func runDeepLink(_ link: PluginDeepLink) {
        guard settings.pluginsEnabled else {
            core.showMessage(String(localized: "Plugins are off — turn them on in Settings"), tone: .danger)
            return
        }
        run(
            link.command, arguments: link.arguments, fallbackText: link.fallbackText, background: link.isBackground,
            context: link.launchContext)
    }

    /// The link Copy Deeplink gives a plugin command's row.
    func deepLink(forEntryID entryID: String, arguments: [String: String]) -> URL? {
        PluginCommandRef(entryID: entryID).flatMap {
            PluginDeepLink.url($0, arguments: arguments, scheme: AppURLScheme.current)
        }
    }

    /// The launcher's fields for a command's arguments, or nil when it declares none.
    func commandArguments(for entry: AppEntry?) -> [PluginArgument]? {
        guard let entry, entry.kind == .pluginCommand, let ref = PluginCommandRef(entryID: entry.id),
            let (_, _, command) = host.resolve(ref), !command.arguments.isEmpty
        else { return nil }
        return command.arguments
    }

    /// A view switches the palette over first, so the launching state is what the user sees.
    private func run(
        _ ref: PluginCommandRef, arguments: [String: String] = [:], fallbackText: String? = nil,
        background: Bool = false, context: [String: PluginValue] = [:]
    ) {
        guard let (manifest, _, command) = host.resolve(ref) else {
            core.showMessage(String(localized: "No plugin provides '\(ref.command)'"), tone: .danger)
            return
        }
        let missing = host.store.missingPreferences(for: manifest, command: command)
        if !background, !missing.isEmpty {
            paletteCoordinator.hidePalette(restoreFocus: false)
            Task {
                guard
                    await core.confirm(
                        title: manifest.title,
                        message: String(
                            localized: "Set \(missing.formatted(.list(type: .and))) in Settings to run this command."),
                        symbol: SettingsTab.plugins.systemImage, confirmTitle: String(localized: "Open Settings"),
                        tone: .neutral, confirmRole: .standard)
                else { return }
                showSettings(for: manifest.name)
            }
            return
        }
        if command.mode == .view, !background {
            showCommand()
            if let fallbackText, !fallbackText.isEmpty { palette.query = fallbackText }
        }
        Task {
            await host.run(ref, arguments: arguments, fallbackText: fallbackText, background: background, context: context)
        }
    }

    /// Escape past an empty search field: back a screen in the plugin, then leave the command.
    func exitCommandScreen() {
        if host.back() { return }
        Task {
            await host.stop()
            if !palette.pop() { paletteCoordinator.hidePalette() }
        }
    }

    /// What no index prunes: left behind, these key a shortcut or a rank to a vanished command.
    func removePluginReferences(entryIDs: [String]) {
        for entryID in entryIDs {
            let action = HotKeyAction.pluginCommand(entryID: entryID)
            if core.hotKeys.recordingAction == action { core.hotKeys.recordingAction = nil }
            core.hotKeys.setBinding(nil, for: action)
            core.launcherRanking.reset(itemKey: entryID)
        }
        core.favorites.remove(keys: Set(entryIDs))
        core.visibility.removeItemKeys(Set(entryIDs))
        core.aliases.removeKeys(Set(entryIDs))
    }

    // MARK: - What a running command asks of the app

    var pasteTarget: NSRunningApplication? { paletteCoordinator.targetApp }

    /// What `getApplications()` reports: what the launcher itself indexes.
    var applicationURLs: [URL] { SearchScopes.appBundles(in: settings.searchScopes) }

    var isShowingCommand: Bool { paletteCoordinator.isVisible && palette.mode == .pluginCommand }

    func showCommand() {
        paletteCoordinator.navigate(to: .pluginCommand)
        if !paletteCoordinator.isVisible { paletteCoordinator.showPalette(mode: .pluginCommand) }
    }

    func closePalette() {
        paletteCoordinator.hidePalette(restoreFocus: false)
    }

    func popToRoot() {
        Task {
            await host.stop()
            palette.prepare(mode: .launcher)
        }
    }

    func clearSearchBar() {
        palette.query = ""
    }

    func paste(_ text: String) {
        let target = pasteTarget
        closePalette()
        Paster.pasteString(text, previousApp: target)
    }

    func showMessage(_ message: String, isError: Bool) {
        core.showMessage(message, tone: isError ? .danger : .success)
    }

    /// The dialog outranks the palette, so a view command keeps its screen behind it.
    func confirm(_ alert: PluginAlert) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return await core.confirm(
            title: alert.title, message: alert.message,
            symbol: alert.isDestructive ? "exclamationmark.triangle" : "questionmark.circle",
            confirmTitle: alert.primaryTitle ?? String(localized: "Confirm"),
            tone: alert.isDestructive ? .danger : .neutral,
            confirmRole: alert.isDestructive ? .destructive : .standard)
    }

    /// The apps that open the file, as a choice when there is more than one.
    func openWith(path: String) async {
        let target = PluginEffects.fileURL(path)
        let candidates = Array(NSWorkspace.shared.urlsForApplications(toOpen: target).prefix(4))
        guard candidates.count > 1 else {
            NSWorkspace.shared.open(target)
            return
        }
        closePalette()
        NSApp.activate(ignoringOtherApps: true)
        let options = candidates.map { DialogAction(title: $0.deletingPathExtension().lastPathComponent) }
        let index = await core.choose(
            title: String(localized: "Open With"), message: target.lastPathComponent, symbol: "arrow.up.forward.app",
            options: options, defaultIndex: 0)
        guard candidates.indices.contains(index) else { return }
        NSWorkspace.shared.open(
            [target], withApplicationAt: candidates[index], configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil)
    }
}
