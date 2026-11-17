import Foundation
import Stir

/// What a plugin command's palette screen shows.
enum PluginScreenState {
    case idle
    case launching
    case page(PluginPage)
    case failed(String)
}

/// Owns the installed plugins, their launcher rows and the one command that runs at a time.
@MainActor
@Observable
final class PluginManager {
    private(set) var isEnabled = false
    private(set) var installed: [InstalledPlugin] = []
    private(set) var screen: PluginScreenState = .idle
    /// The running command's entry id, which the palette's mode is about.
    private(set) var runningEntryID: String?
    /// Above one, Escape pops the plugin's own stack before it leaves the command.
    private(set) var navigationDepth = 1

    @ObservationIgnored private var session: PluginSession?
    @ObservationIgnored private weak var appIndex: AppIndex?
    @ObservationIgnored private weak var services: (any PluginHostServices)?
    @ObservationIgnored private var kit: PluginSources?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var launchToken = 0
    /// Told when an action command ends, so the palette has nothing left to show.
    @ObservationIgnored var onFinish: () -> Void = {}

    func start(appIndex: AppIndex, services: any PluginHostServices) {
        self.appIndex = appIndex
        self.services = services
    }

    // MARK: - The switch

    /// Idempotent both ways. Off means nothing scanned, watched or held.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        guard enabled else {
            stop()
            watcher?.cancel()
            watcher = nil
            installed = []
            appIndex?.setPluginCommands([])
            return
        }
        await refresh()
        watchDirectory()
        warmKit()
    }

    func refresh() async {
        guard isEnabled else { return }
        let directory = PluginCatalog.pluginsDirectory()
        let found = await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return PluginCatalog.scan(directory)
        }.value
        guard isEnabled, found != installed else { return }
        installed = found
        appIndex?.setPluginCommands(launcherEntries())
    }

    /// Adding or removing a plugin folder rescans; a plugin's code is read fresh on every launch.
    private func watchDirectory() {
        let directory = PluginCatalog.pluginsDirectory()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    /// Compiling the kit is most of a first launch; doing it once now leaves a launch ~15 ms.
    private func warmKit() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.isEnabled, let kit = await self.kitSources() else { return }
            let context = StirContext(modules: [PluginSession.hostModule], output: { _ in })
            _ = try? context.load(
                files: kit.files.map { SourceFile(name: $0.name, text: $0.text) }, moduleName: "Tinycast")
        }
    }

    // MARK: - Launcher rows

    private func launcherEntries() -> [AppEntry] {
        installed.flatMap { plugin -> [AppEntry] in
            guard case .success(let manifest) = plugin.manifest else { return [] }
            return manifest.commands.map { command in
                AppEntry(
                    id: InstalledPlugin.entryID(plugin: manifest.name, command: command.name),
                    name: command.title, url: plugin.directory, bundleID: nil, kind: .pluginCommand,
                    subtitle: command.subtitle ?? manifest.title, keywords: command.keywords,
                    iconOverride: .tile(
                        symbol: command.icon ?? manifest.icon ?? "puzzlepiece", tint: SettingsTab.plugins.tint),
                    ownerName: manifest.title)
            }
        }
    }

    func resolve(entryID: String) -> (manifest: PluginManifest, directory: URL, command: PluginCommand)? {
        for plugin in installed {
            guard case .success(let manifest) = plugin.manifest else { continue }
            for command in manifest.commands
            where InstalledPlugin.entryID(plugin: manifest.name, command: command.name) == entryID {
                return (manifest, plugin.directory, command)
            }
        }
        return nil
    }

    // MARK: - Running a command

    /// Starts the command behind `entryID`, ending whatever ran before it.
    func run(entryID: String) async {
        guard isEnabled, let services, let (manifest, directory, command) = resolve(entryID: entryID)
        else { return }
        stop()
        launchToken += 1
        let token = launchToken
        runningEntryID = entryID
        screen = .launching
        let read = await Task.detached(priority: .userInitiated) {
            Result { () throws(PluginSources.ReadError) -> PluginSources in
                try PluginSources.read(from: directory)
            }
        }.value
        guard token == launchToken else { return }
        guard let kit = await kitSources() else { return fail(PluginSessionError.kitMissing) }
        guard token == launchToken else { return }
        let sources: PluginSources
        switch read {
        case .success(let read): sources = read
        case .failure(let error): return fail(PluginSessionError.sources(error.description))
        }
        let session: PluginSession
        do {
            session = try PluginSession(
                manifest: manifest, command: command, sources: sources, kit: kit,
                storage: PluginStorage(fileURL: PluginCatalog.storageFile(for: manifest.name)),
                services: services)
        } catch {
            return fail(error)
        }
        self.session = session
        session.onChange = { [weak self, weak session] in
            guard let self, let session, self.session === session else { return }
            self.apply(session)
        }
        switch command.mode {
        case .view: await session.open()
        case .action: await session.run()
        }
    }

    private func apply(_ session: PluginSession) {
        navigationDepth = session.navigationDepth
        switch session.state {
        case .running(let page): screen = .page(page)
        case .failed(let message): screen = .failed(message)
        case .finished:
            stop()
            onFinish()
        }
    }

    private func fail(_ error: any Error) {
        screen = .failed((error as? PluginSessionError)?.description ?? String(describing: error))
    }

    /// Runs one of the screen's actions; copy, paste and open never reach the script.
    func perform(_ action: PluginAction) {
        switch action.kind {
        case .perform(let body): session?.call { try body() }
        case .copy(let text): services?.copy(text)
        case .paste(let text): services?.paste(text)
        case .open(let target): services?.open(target)
        }
    }

    func searchTextChanged(_ text: String, search: PluginSearch) {
        guard text != search.text else { return }
        session?.call { try search.onChange(text) }
    }

    /// False at the command's root, where Escape leaves it.
    func goBack() -> Bool {
        session?.goBack() ?? false
    }

    func stop() {
        launchToken += 1
        session?.close()
        session = nil
        runningEntryID = nil
        navigationDepth = 1
        screen = .idle
    }

    /// What the running command printed, for its error screen.
    var output: String { session?.output ?? "" }

    private func kitSources() async -> PluginSources? {
        if let kit { return kit }
        guard let directory = PluginCatalog.kitDirectory() else { return nil }
        let read = await Task.detached(priority: .userInitiated) {
            try? PluginSources.read(from: directory, requiringMain: false)
        }.value
        kit = read
        return read
    }
}
