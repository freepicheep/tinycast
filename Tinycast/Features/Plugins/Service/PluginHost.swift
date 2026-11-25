import AppKit
import Foundation

/// Runs plugin commands: a view in the palette, one at a time; an action on its own, closing the
/// palette, and again on its interval in the background; a menu-bar command in the menu bar. Owns
/// their runtimes, what the palette's last drew, and the launcher rows the commands are listed as.
@MainActor
@Observable
final class PluginHost {
    enum State: Equatable {
        case idle
        case launching
        case rendered(PluginFrame)
        case failed(String)
    }

    struct Toast: Identifiable, Equatable {
        let id: Int
        var content: PluginToast
    }

    private(set) var state: State = .idle
    private(set) var running: PluginCommandRef?
    private(set) var toasts: [Toast] = []
    private(set) var isSigningIn = false

    var frame: PluginFrame? {
        if case .rendered(let frame) = state { return frame }
        return nil
    }

    @ObservationIgnored let store: PluginStore
    @ObservationIgnored private let plugins: PluginManager
    @ObservationIgnored private weak var appIndex: AppIndex?
    @ObservationIgnored weak var coordinator: PluginCoordinator?
    @ObservationIgnored private var palette: Lane?
    @ObservationIgnored private var paletteInputs: Inputs?
    @ObservationIgnored private var actions: [String: Lane] = [:]
    @ObservationIgnored private var menuBars: [PluginCommandRef: Lane] = [:]
    @ObservationIgnored private var menuBarItems: [PluginCommandRef: PluginMenuBarItem] = [:]
    @ObservationIgnored private var menuBarRefreshes: [PluginCommandRef: Task<Void, Never>] = [:]
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?
    @ObservationIgnored private var nextToastID = 1

    /// What a launch was given, so an edit to the plugin can launch it again the same way.
    private struct Inputs {
        var arguments: [String: String]
        var fallbackText: String?
        var context: [String: PluginValue]
    }

    init(plugins: PluginManager, store: PluginStore = PluginStore()) {
        self.plugins = plugins
        self.store = store
    }

    func start(appIndex: AppIndex, coordinator: PluginCoordinator) {
        self.appIndex = appIndex
        self.coordinator = coordinator
        plugins.host = self
    }

    // MARK: - The installed set

    /// The plugins folder changed, or plugins were turned on or off.
    func installedChanged() {
        publishLauncherEntries()
        syncMenuBars()
        restartBackground()
        guard let running, resolve(running) == nil else { return }
        Task { await stop() }
    }

    /// A command's manifest, folder and declaration, while its plugin is installed and readable.
    func resolve(_ ref: PluginCommandRef) -> (PluginManifest, URL, PluginCommand)? {
        guard let (manifest, directory) = plugins.plugin(named: ref.plugin),
            let command = manifest.commands.first(where: { $0.name == ref.command })
        else { return nil }
        return (manifest, directory, command)
    }

    func launcherEntry(forEntryID entryID: String) -> AppEntry? {
        guard let ref = PluginCommandRef(entryID: entryID), let (manifest, directory, command) = resolve(ref) else {
            return nil
        }
        return entry(command, of: manifest, in: directory)
    }

    private func publishLauncherEntries() {
        let entries = plugins.readable.flatMap { manifest, directory in
            manifest.commands.map { entry($0, of: manifest, in: directory) }
        }
        appIndex?.setPluginCommands(
            entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    private func entry(_ command: PluginCommand, of manifest: PluginManifest, in directory: URL) -> AppEntry {
        let ref = PluginCommandRef(plugin: manifest.name, command: command.name)
        return AppEntry(
            id: ref.entryID, name: command.title, url: directory, bundleID: nil, kind: .pluginCommand,
            subtitle: store.settings(ref).subtitle ?? command.subtitle, keywords: command.keywords,
            iconOverride: .tile(
                symbol: command.icon ?? manifest.icon ?? "puzzlepiece", tint: SettingsTab.plugins.tint),
            ownerName: manifest.title)
    }

    // MARK: - Running a command

    /// A view takes over the palette; an action runs on its own; a menu-bar command refreshes.
    func run(
        _ ref: PluginCommandRef, arguments: [String: String] = [:], fallbackText: String? = nil,
        background: Bool = false, context: [String: PluginValue] = [:]
    ) async {
        guard let (manifest, directory, command) = resolve(ref) else {
            if !background {
                coordinator?.showMessage(String(localized: "No plugin provides '\(ref.command)'"), isError: true)
            }
            return
        }
        let launch = PluginLaunch(
            commandName: command.name, isBackground: background,
            arguments: completeArguments(arguments, for: command),
            preferences: store.preferences(for: manifest, command: command), fallbackText: fallbackText,
            launchContext: context, isDarkAppearance: NSApp.effectiveAppearance.isDark)
        switch command.mode {
        case .view:
            await runInPalette(ref, manifest: manifest, directory: directory, launch: launch)
            paletteInputs = Inputs(arguments: arguments, fallbackText: fallbackText, context: context)
        case .action:
            runAction(ref, manifest: manifest, directory: directory, launch: launch)
        case .menuBar:
            showMenuBar(ref, manifest: manifest, directory: directory, launch: launch)
        }
    }

    /// Every declared argument, empty when the launcher left it unfilled.
    private func completeArguments(_ arguments: [String: String], for command: PluginCommand) -> [String: String] {
        var complete = arguments
        for argument in command.arguments where complete[argument.name] == nil { complete[argument.name] = "" }
        return complete
    }

    private func runInPalette(
        _ ref: PluginCommandRef, manifest: PluginManifest, directory: URL, launch: PluginLaunch
    ) async {
        await stop()
        running = ref
        state = .launching
        let lane = makeLane(ref, manifest: manifest, directory: directory, kind: .palette)
        palette = lane
        lane.onRender = { [weak self, weak lane] frame in
            guard let self, let lane, self.palette === lane else { return }
            self.state = .rendered(frame)
        }
        lane.onFail = { [weak self, weak lane] message in
            guard let self, let lane, self.palette === lane else { return }
            self.state = .failed(message)
        }
        do {
            try await lane.runtime.launch(session: lane.session, launch: launch)
        } catch {
            guard palette === lane else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// The palette's command starts again from its plugin's new code, as it was launched.
    func relaunch(plugin: String) async {
        guard let running, running.plugin == plugin, state != .idle, let inputs = paletteInputs else { return }
        await run(running, arguments: inputs.arguments, fallbackText: inputs.fallbackText, context: inputs.context)
        for (ref, _) in menuBars where ref.plugin == plugin { refreshMenuBar(ref) }
    }

    func stop() async {
        let lane = palette
        palette = nil
        paletteInputs = nil
        state = .idle
        running = nil
        toasts = []
        guard let lane else { return }
        await lane.runtime.stop(session: lane.session)
        lane.runtime.shutdown()
        store.flush()
    }

    /// Stops everything: plugins were turned off.
    func stopAll() async {
        await stop()
        backgroundTask?.cancel()
        backgroundTask = nil
        for lane in Array(actions.values) + Array(menuBars.values) {
            await lane.runtime.stop(session: lane.session)
            lane.runtime.shutdown()
        }
        actions = [:]
        menuBars = [:]
        for task in menuBarRefreshes.values { task.cancel() }
        menuBarRefreshes = [:]
        for item in menuBarItems.values { item.remove() }
        menuBarItems = [:]
        publishLauncherEntries()
    }

    // MARK: - Events from the palette

    func send(_ event: PluginEvent) {
        guard let lane = palette else { return }
        Task { await lane.runtime.send(event, session: lane.session, completesSession: false) }
    }

    /// An action the user chose: its effect, which the app performs, then the plugin's handler.
    func perform(_ action: PluginAction) {
        guard let frame, let ref = running, let (manifest, _, _) = resolve(ref) else { return }
        if let effect = action.effect { perform(effect, for: manifest) }
        if let handler = action.handler { send(.perform(handler, generation: frame.generation)) }
    }

    func search(_ text: String) {
        guard let frame, frame.screen.chrome?.search?.binding != nil else { return }
        send(.search(text, generation: frame.generation))
    }

    func set(_ node: String, _ value: PluginFieldValue) {
        guard let frame else { return }
        send(.set(node, value: value, generation: frame.generation))
    }

    /// False when the command is on its first screen, which leaving takes down.
    func back() -> Bool {
        guard let frame, frame.depth > 1 else { return false }
        send(.back)
        return true
    }

    func runToastAction(token: String) {
        guard let lane = palette else { return }
        Task { await lane.runtime.runToastAction(token: token) }
    }

    private func perform(_ effect: PluginEffect, for manifest: PluginManifest) {
        switch effect {
        case .openURL(let target, let application):
            guard let url = PluginOpenTarget.resolve(target, schemes: manifest.urlSchemes) else {
                coordinator?.showMessage(String(localized: "This plugin can't open “\(target)”"), isError: true)
                return
            }
            PluginEffects.open(url, application: application)
            coordinator?.closePalette()
        case .copy(let text, let concealed):
            PluginEffects.copy(text, concealed: concealed)
            coordinator?.closePalette()
            coordinator?.showMessage(String(localized: "Copied to Clipboard"), isError: false)
        case .paste(let text):
            coordinator?.paste(text)
        case .revealInFinder(let path):
            PluginEffects.reveal(path)
            coordinator?.closePalette()
        case .openWith(let path):
            Task { await coordinator?.openWith(path: path) }
        case .trash(let paths):
            PluginEffects.trash(paths)
        case .push, .submit, .section, .menu, .unsupported:
            break
        }
    }

    // MARK: - Actions

    /// Each run has a runtime of its own, discarded when it finishes, fails or takes too long.
    private func runAction(_ ref: PluginCommandRef, manifest: PluginManifest, directory: URL, launch: PluginLaunch) {
        if !launch.isBackground { coordinator?.closePalette() }
        let lane = makeLane(ref, manifest: manifest, directory: directory, kind: launch.isBackground ? .background : .action)
        let key = lane.session
        actions[key] = lane
        let end: (String?) -> Void = { [weak self] failure in
            guard let self, let lane = self.actions.removeValue(forKey: key) else { return }
            if let failure, !launch.isBackground {
                self.coordinator?.showMessage(failure, isError: true)
            }
            self.store.updateSettings(ref) { $0.lastRun = Date() }
            Task {
                await lane.runtime.stop(session: lane.session)
                lane.runtime.shutdown()
            }
        }
        lane.onFinish = { end(nil) }
        lane.onFail = { end($0) }
        Task {
            do {
                try await lane.runtime.launch(session: lane.session, launch: launch)
            } catch {
                end(error.localizedDescription)
            }
            try? await Task.sleep(for: .seconds(Self.actionTimeLimit))
            end(nil)
        }
    }

    /// Past this an action that never returned is stopped: a timer or a forgotten task.
    static let actionTimeLimit: TimeInterval = 120

    // MARK: - Background

    /// Actions with an interval the user hasn't turned off, run when due, one at a time.
    func restartBackground() {
        backgroundTask?.cancel()
        backgroundTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = self.runDueBackgroundActions()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func runsInBackground(_ ref: PluginCommandRef) -> Bool {
        guard let (_, _, command) = resolve(ref), command.mode == .action, command.interval != nil else { return false }
        return store.settings(ref).runsInBackground ?? true
    }

    func setRunsInBackground(_ enabled: Bool, _ ref: PluginCommandRef) {
        store.updateSettings(ref) { $0.runsInBackground = enabled ? nil : false }
        restartBackground()
    }

    /// Runs what is due and returns how long until the next is.
    private func runDueBackgroundActions() -> TimeInterval {
        let now = Date()
        var next: TimeInterval = 3600
        for (manifest, _) in plugins.readable {
            for command in manifest.commands where command.mode == .action {
                let ref = PluginCommandRef(plugin: manifest.name, command: command.name)
                guard let declared = command.interval, runsInBackground(ref) else { continue }
                let interval = max(declared, Self.minimumBackgroundInterval)
                let due = store.settings(ref).lastRun.map { $0.addingTimeInterval(interval) } ?? now
                if due <= now {
                    if !actions.values.contains(where: { $0.ref == ref }) {
                        Task { await run(ref, background: true) }
                    }
                    next = min(next, interval)
                } else {
                    next = min(next, due.timeIntervalSince(now))
                }
            }
        }
        return max(next, 1)
    }

    static let minimumBackgroundInterval: TimeInterval = 60

    // MARK: - Menu bar

    func showsInMenuBar(_ ref: PluginCommandRef) -> Bool {
        guard let (_, _, command) = resolve(ref), command.mode == .menuBar else { return false }
        return store.settings(ref).showsInMenuBar ?? true
    }

    func setShowsInMenuBar(_ shown: Bool, _ ref: PluginCommandRef) {
        store.updateSettings(ref) { $0.showsInMenuBar = shown ? nil : false }
        syncMenuBars()
    }

    /// One status item per shown menu-bar command, each with its runtime kept running.
    private func syncMenuBars() {
        var wanted: Set<PluginCommandRef> = []
        for (manifest, _) in plugins.readable {
            for command in manifest.commands where command.mode == .menuBar {
                let ref = PluginCommandRef(plugin: manifest.name, command: command.name)
                if showsInMenuBar(ref) { wanted.insert(ref) }
            }
        }
        for ref in Set(menuBars.keys).union(menuBarItems.keys).subtracting(wanted) { removeMenuBar(ref) }
        for ref in wanted where menuBars[ref] == nil { Task { await run(ref, background: true) } }
    }

    private func showMenuBar(_ ref: PluginCommandRef, manifest: PluginManifest, directory: URL, launch: PluginLaunch) {
        guard showsInMenuBar(ref) else { return }
        if let old = menuBars.removeValue(forKey: ref) {
            Task {
                await old.runtime.stop(session: old.session)
                old.runtime.shutdown()
            }
        }
        let lane = makeLane(ref, manifest: manifest, directory: directory, kind: .menuBar)
        menuBars[ref] = lane
        let item = menuBarItems[ref] ?? PluginMenuBarItem(title: manifest.title)
        menuBarItems[ref] = item
        item.onPerform = { [weak lane] handler, generation in
            guard let lane else { return }
            Task { await lane.runtime.send(.perform(handler, generation: generation), session: lane.session, completesSession: false) }
        }
        lane.onRender = { [weak item] frame in
            if case .menuBar(let screen) = frame.screen { item?.show(screen, generation: frame.generation) }
        }
        lane.onFail = { [weak item] message in item?.showFailure(message) }
        Task {
            do {
                try await lane.runtime.launch(session: lane.session, launch: launch)
            } catch {
                item.showFailure(error.localizedDescription)
            }
        }
        menuBarRefreshes[ref]?.cancel()
        if let interval = resolve(ref)?.2.interval {
            let wait = max(interval, Self.minimumMenuBarInterval)
            menuBarRefreshes[ref] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.refreshMenuBar(ref)
            }
        }
    }

    static let minimumMenuBarInterval: TimeInterval = 10

    private func refreshMenuBar(_ ref: PluginCommandRef) {
        Task { await run(ref, background: true) }
    }

    private func removeMenuBar(_ ref: PluginCommandRef) {
        menuBarRefreshes.removeValue(forKey: ref)?.cancel()
        menuBarItems.removeValue(forKey: ref)?.remove()
        guard let lane = menuBars.removeValue(forKey: ref) else { return }
        Task {
            await lane.runtime.stop(session: lane.session)
            lane.runtime.shutdown()
        }
    }

    // MARK: - What a command asks of the app

    /// Called by a lane's bridge; the palette's toasts show only while its command is up.
    func present(_ toast: PluginToast, from kind: PluginHostBridge.Kind) -> Int {
        let id = nextToastID
        nextToastID += 1
        guard kind == .palette, coordinator?.isShowingCommand == true else {
            if kind != .background {
                coordinator?.showMessage(toast.title, isError: toast.style == .failure)
            }
            return id
        }
        toasts.append(Toast(id: id, content: toast))
        if toast.style != .animated { dismissToast(id, after: 3) }
        return id
    }

    func update(toast id: Int, with toast: PluginToast) {
        guard let index = toasts.firstIndex(where: { $0.id == id }) else { return }
        toasts[index].content = toast
        if toast.style != .animated { dismissToast(id, after: 3) }
    }

    func hide(toast id: Int) {
        toasts.removeAll { $0.id == id }
    }

    private func dismissToast(_ id: Int, after seconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.hide(toast: id)
        }
    }

    func updateSubtitle(_ subtitle: String?, for ref: PluginCommandRef) {
        store.updateSettings(ref) { $0.subtitle = subtitle }
        publishLauncherEntries()
    }

    /// Another of the plugin's commands, from `launchCommand`.
    func launch(_ ref: PluginCommandRef, background: Bool, arguments: [String: String], context: [String: PluginValue]) {
        guard let (_, _, command) = resolve(ref) else { return }
        if command.mode == .view, !background { coordinator?.showCommand() }
        Task { await run(ref, arguments: arguments, background: background, context: context) }
    }

    func signIn(url: URL, callbackScheme: String) async throws -> URL {
        guard !isSigningIn else { throw PluginHostError(message: "Another sign-in is already open.") }
        isSigningIn = true
        defer { isSigningIn = false }
        let redirect = try await PluginSignInSession().run(url: url, callbackScheme: callbackScheme)
        if running != nil { coordinator?.showCommand() }
        return redirect
    }

    // MARK: - Lanes

    private func makeLane(
        _ ref: PluginCommandRef, manifest: PluginManifest, directory: URL, kind: PluginHostBridge.Kind
    ) -> Lane {
        let bridge = PluginHostBridge(host: self, plugin: manifest, command: ref, kind: kind)
        let runtime = plugins.makeRuntime(plugin: manifest, directory: directory, storage: store, hostAPI: bridge)
        let lane = Lane(ref: ref, runtime: runtime)
        runtime.setDelegate(lane)
        return lane
    }

    /// One running command: its runtime, and what the host does with what the runtime reports.
    @MainActor
    final class Lane: PluginRuntimeDelegate {
        let ref: PluginCommandRef
        let runtime: any PluginRuntime
        let session = UUID().uuidString
        var onRender: (PluginFrame) -> Void = { _ in }
        var onFail: (String) -> Void = { _ in }
        var onFinish: () -> Void = {}

        init(ref: PluginCommandRef, runtime: any PluginRuntime) {
            self.ref = ref
            self.runtime = runtime
        }

        func runtime(_ runtime: any PluginRuntime, session: String, didRender frame: PluginFrame) {
            guard session == self.session else { return }
            // A newer minor version draws placeholders; a newer major one can't be read.
            guard frame.version.major == PluginProtocolVersion.current.major else {
                onFail(String(localized: "This version of Tinycast can't show this screen"))
                return
            }
            onRender(frame)
        }

        func runtime(_ runtime: any PluginRuntime, session: String, didFail message: String) {
            guard session == self.session else { return }
            onFail(message)
        }

        func runtime(_ runtime: any PluginRuntime, session: String, didFinish: Void) {
            guard session == self.session else { return }
            onFinish()
        }
    }
}
