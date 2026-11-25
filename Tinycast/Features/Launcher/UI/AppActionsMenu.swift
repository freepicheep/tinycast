import SwiftUI

@MainActor
enum AppActionsMenu {
    static func content(
        app: AppEntry, searchQuery: String, core: AppCore, running: Bool,
        favorites: FavoriteActions, onResetRanking: @escaping () -> Void,
        onHideFromSearch: @escaping () -> Void
    ) -> PopoverMenuContent {
        var items = leadingItems(app: app, searchQuery: searchQuery, core: core)
        // A query-driven row lives only for its query, so no preference could outlive it.
        let isPersistent = !CommandCatalog.isQueryDriven(app)
        if isPersistent { items.append(contentsOf: favorites.items) }
        if let deepLink = core.launcherCoordinator.deepLink(for: app) {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Copy Deeplink"), systemImage: "link", shortcut: "⇧⌘C"
                ) {
                    core.launcherCoordinator.copyDeepLink(deepLink)
                })
        }
        if core.launcherRanking.hasRanking(for: app.preferenceKey) {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Reset Ranking"), systemImage: "arrow.counterclockwise"
                ) {
                    onResetRanking()
                })
        }
        // These carry their own Show in root search switch rather than a pane checkbox.
        let hidesFromRoot = app.kind == .quicklink || app.kind == .customCommand
        if isPersistent, app.canHideFromSearch || hidesFromRoot {
            let title =
                hidesFromRoot
                ? String(localized: "Hide from Root Search") : String(localized: "Hide from Search")
            items.append(
                PopoverMenuItem(
                    title: title, systemImage: "eye.slash", shortcut: "⇧⌘H", action: onHideFromSearch))
        }
        if running, app.kind == .application {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Restart Application"), systemImage: "arrow.clockwise",
                    startsSection: true, shortcut: "⌘R"
                ) {
                    core.launcherCoordinator.restart(app)
                })
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Quit Application"), systemImage: "power", shortcut: "⌃⇧Q"
                ) {
                    core.launcherCoordinator.quit(app)
                })
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Force Quit Application"), systemImage: "xmark.circle",
                    shortcut: "⌃⌥⇧Q"
                ) {
                    core.launcherCoordinator.quit(app, force: true)
                })
        }
        if app.kind == .application, app.primaryInstallationID == nil {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Uninstall Application"), systemImage: "trash",
                    startsSection: true, isDestructive: true
                ) {
                    core.uninstallCoordinator.beginUninstall(app)
                })
        }
        if app.kind == .quicklink, let quicklink = core.quicklinks.quicklink(entryID: app.id) {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Copy Link"), systemImage: "doc.on.clipboard",
                    startsSection: true, shortcut: "⌃⌘C"
                ) {
                    core.quicklinkCoordinator.copyQuicklink(id: quicklink.id)
                })
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Edit Quicklink"), systemImage: "pencil", shortcut: "⌘E"
                ) {
                    core.quicklinkCoordinator.editQuicklink(quicklink)
                })
        }
        if app.kind == .pluginCommand, let ref = PluginCommandRef(entryID: app.id) {
            let host = core.pluginHost
            if let (_, _, command) = host.resolve(ref), command.mode == .action, command.interval != nil {
                let enabled = host.runsInBackground(ref)
                items.append(
                    PopoverMenuItem(
                        title: enabled
                            ? String(localized: "Stop Running in the Background")
                            : String(localized: "Run in the Background"),
                        systemImage: enabled ? "pause.circle" : "play.circle", startsSection: true
                    ) {
                        host.setRunsInBackground(!enabled, ref)
                    })
            }
            // A plugin is a folder the user keeps, so it is configured here and removed in Finder.
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Configure Plugin"), systemImage: "slider.horizontal.3",
                    startsSection: true
                ) {
                    core.pluginCoordinator.showSettings(for: ref.plugin)
                })
        }
        return PopoverMenuContent(header: app.name, items: items)
    }

    private static func leadingItems(
        app: AppEntry, searchQuery: String, core: AppCore
    ) -> [PopoverMenuItem] {
        if app.kind == .meeting, let meeting = core.calendarCoordinator.meeting(entryID: app.id) {
            return MeetingActionsMenu.content(meeting: meeting, core: core).items
        }
        if app.kind == .customCommand, let command = core.customCommands.command(entryID: app.id) {
            return CustomCommandActionsMenu.leadingItems(
                command: command, coordinator: core.customCommandCoordinator
            ) {
                core.launcherCoordinator.launch(app, searchQuery: searchQuery)
            }
        }
        let primarySymbol =
            switch app.kind {
            case .application, .command, .pluginCommand: "list.dash.header.rectangle"
            default: "list.bullet.rectangle"
            }
        var items = [
            PopoverMenuItem(
                title: app.kind.descriptor.openVerb.resolved(), systemImage: primarySymbol,
                shortcut: "↵"
            ) { core.launcherCoordinator.launch(app, searchQuery: searchQuery) }
        ]
        if app.kind == .snippet, let id = StoredSnippet.id(fromEntryID: app.id),
            let record = core.snippetsStore.record(id: id)
        {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Edit Snippet"), systemImage: "pencil", shortcut: "⌘E"
                ) {
                    core.snippetCoordinator.editSnippet(record)
                })
        }
        if app.canRevealInFinder {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Show in Finder"), systemImage: "folder", shortcut: "⌘↵"
                ) {
                    core.launcherCoordinator.showInFinder(app)
                })
        }
        return items
    }
}
