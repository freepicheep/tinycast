import Foundation

/// Deletes what Raycast extensions left behind once Tinycast stopped running them: the installed
/// extensions and their data, their settings and shortcuts, and every launcher key of a command.
@MainActor
enum RaycastExtensionsMigration {
    /// Under Application Support, beside the files that outlive this release.
    static let supportItems = [
        "extensions", "extension-data", "extension-support", "extension-commands.json",
        "extension-versions.json"
    ]

    static let defaultsKeys = [
        "extensionsEnabled", "extensionsShowInLauncher", "extensionPackageManager",
        "extensionCustomSearchPaths",
        "extensionAppearances", "boundExtensionCommandEntryIDs"
    ]

    static let hotKeyPrefix = "hotkey.extensionCommand."
    static let entryPrefix = "extension:"

    /// What settings.json said about extensions; a file that still says it reads as a mistake.
    static let settingsFilePaths: Set<String> = ["extensions", "extensions.showInLauncher"]

    /// One store keyed by launcher entry: favorites, hidden rows, aliases or ranking.
    struct EntryKeys {
        let keys: () -> [String]
        let remove: (Set<String>) -> Void
    }

    static func run(
        entryKeys: [EntryKeys], defaults: UserDefaults = .standard,
        support: URL = AppPaths.applicationSupport(),
        settingsFile: URL = AppPaths.settingsFile()
    ) {
        let files = FileManager.default
        for item in supportItems {
            let url = support.appending(path: item)
            if files.fileExists(atPath: url.path) { try? files.removeItem(at: url) }
        }
        for key in defaultsKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(hotKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
        for store in entryKeys {
            let retired = Set(store.keys().filter { $0.hasPrefix(entryPrefix) })
            if !retired.isEmpty { store.remove(retired) }
        }
        removeSettingsFileKeys(at: settingsFile)
    }

    /// Rewritten only when the retired keys are all that is wrong, so no other typo goes quietly.
    private static func removeSettingsFileKeys(at url: URL) {
        guard let data = try? Data(contentsOf: url), let parsed = try? SettingsFileFormat.parse(data) else {
            return
        }
        let retired = parsed.issues.filter {
            if case .unknownSetting(let path) = $0 { return settingsFilePaths.contains(path) }
            return false
        }
        guard !retired.isEmpty, retired.count == parsed.issues.count else { return }
        try? SettingsFileFormat.render(parsed.values).write(
            to: url.resolvingSymlinksInPath(), options: .atomic)
    }
}
