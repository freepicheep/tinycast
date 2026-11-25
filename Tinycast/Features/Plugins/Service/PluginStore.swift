import Foundation

/// Everything Tinycast keeps for a plugin, one JSON file each in Application Support: its
/// `@AppStorage` values, the preferences the user set, its OAuth tokens and its commands' settings.
/// The main app writes it; Settings' process reads it.
@MainActor
final class PluginStore: PluginStorage {
    /// What one command's launcher row and lanes remember.
    struct CommandSettings: Codable, Sendable, Equatable {
        /// Set by `updateCommandMetadata(subtitle:)`; nil shows the manifest's.
        var subtitle: String?
        /// An action with an interval runs in the background unless turned off.
        var runsInBackground: Bool?
        /// A menu-bar command shows its menu unless turned off.
        var showsInMenuBar: Bool?
        var lastRun: Date?
    }

    private struct File: Codable, Equatable {
        var values: [String: String] = [:]
        var preferences: [String: PluginValue] = [:]
        var tokens: [String: PluginOAuthTokens] = [:]
        var commands: [String: CommandSettings] = [:]
    }

    private let directory: URL
    private var files: [String: File] = [:]
    private var dirty: Set<String> = []
    private var flushTask: Task<Void, Never>?

    init(directory: URL = PluginStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        AppPaths.applicationSupport().appending(path: "PluginData", directoryHint: .isDirectory)
    }

    // MARK: - PluginStorage

    func value(plugin: String, key: String) -> String? { file(plugin).values[key] }
    func values(plugin: String) -> [String: String] { file(plugin).values }
    func setValue(_ value: String?, plugin: String, key: String) { mutate(plugin) { $0.values[key] = value } }
    func clearValues(plugin: String) { mutate(plugin) { $0.values = [:] } }

    // MARK: - Preferences

    func preference(plugin: String, name: String) -> PluginValue? { file(plugin).preferences[name] }

    /// Nil puts back the manifest's default.
    func setPreference(_ value: PluginValue?, plugin: String, name: String) {
        mutate(plugin) { $0.preferences[name] = value }
    }

    /// Every declared preference's value as a command reads it: the user's, else the default.
    func preferences(for manifest: PluginManifest, command: PluginCommand) -> [String: PluginValue] {
        let stored = file(manifest.name).preferences
        var values: [String: PluginValue] = [:]
        for preference in manifest.preferences + command.preferences {
            if let value = stored[preference.name] ?? preference.defaultValue { values[preference.name] = value }
        }
        return values
    }

    /// The required preferences the user hasn't set, by title.
    func missingPreferences(for manifest: PluginManifest, command: PluginCommand) -> [String] {
        let values = preferences(for: manifest, command: command)
        return (manifest.preferences + command.preferences).compactMap { preference in
            guard preference.required == true else { return nil }
            switch values[preference.name] {
            case .string(let text)? where !text.isEmpty: return nil
            case .bool?, .number?: return nil
            default: return preference.title
            }
        }
    }

    // MARK: - OAuth

    func tokens(plugin: String, provider: String) -> PluginOAuthTokens? { file(plugin).tokens[provider] }

    func setTokens(_ tokens: PluginOAuthTokens?, plugin: String, provider: String) {
        mutate(plugin) { $0.tokens[provider] = tokens }
    }

    func isSignedIn(plugin: String) -> Bool { !file(plugin).tokens.isEmpty }

    func signOut(plugin: String) { mutate(plugin) { $0.tokens = [:] } }

    /// What Settings shows: every preference the user set, by name.
    func preferences(plugin: String) -> [String: PluginValue] { file(plugin).preferences }

    // MARK: - Commands

    func settings(_ command: PluginCommandRef) -> CommandSettings {
        file(command.plugin).commands[command.command] ?? CommandSettings()
    }

    func updateSettings(_ command: PluginCommandRef, _ change: (inout CommandSettings) -> Void) {
        mutate(command.plugin) { file in
            var settings = file.commands[command.command] ?? CommandSettings()
            change(&settings)
            file.commands[command.command] = settings == CommandSettings() ? nil : settings
        }
    }

    /// Everything kept for a plugin, as when its folder is removed.
    func removeAll(plugin: String) {
        files[plugin] = File()
        dirty.insert(plugin)
        scheduleFlush()
    }

    /// Forgets what was read, so the next read sees what another process wrote.
    func reload() {
        flush()
        files = [:]
    }

    // MARK: - Files

    private func file(_ plugin: String) -> File {
        if let file = files[plugin] { return file }
        let read = (try? Data(contentsOf: url(plugin))).flatMap { try? JSONDecoder().decode(File.self, from: $0) }
        files[plugin] = read ?? File()
        return files[plugin]!
    }

    private func mutate(_ plugin: String, _ change: (inout File) -> Void) {
        var file = file(plugin)
        change(&file)
        guard file != files[plugin] else { return }
        files[plugin] = file
        dirty.insert(plugin)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.flush()
        }
    }

    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !dirty.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for plugin in dirty {
            let file = files[plugin] ?? File()
            if file == File() {
                try? FileManager.default.removeItem(at: url(plugin))
            } else if let data = try? encoder.encode(file) {
                try? data.write(to: url(plugin), options: .atomic)
            }
        }
        dirty = []
    }

    private func url(_ plugin: String) -> URL {
        directory.appending(path: "\(plugin).json", directoryHint: .notDirectory)
    }
}
