import Foundation

@main
@MainActor
struct RaycastExtensionsMigrationTests {
    static var failures = 0

    static func main() throws {
        try testRemovesWhatExtensionsLeft()
        try testSettingsFile()
        try testNothingToDo()

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            print("  ✓ \(message)")
        } else {
            print("  ✗ \(message)")
            failures += 1
        }
    }

    final class Keys {
        var keys: [String]
        init(_ keys: [String]) { self.keys = keys }

        var store: RaycastExtensionsMigration.EntryKeys {
            .init(keys: { self.keys }, remove: { removed in self.keys.removeAll { removed.contains($0) } })
        }
    }

    /// A suite of its own, so a run never touches the harness's standard defaults.
    static let scratchDefaults = UserDefaults(suiteName: "RaycastExtensionsMigrationTests.scratch")!

    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "raycast-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func testRemovesWhatExtensionsLeft() throws {
        print("What extensions left")
        let support = try scratch()
        let files = FileManager.default
        for directory in ["extensions/raycast-demo", "extension-data", "extension-support/demo", "PluginData"]
        {
            try files.createDirectory(
                at: support.appending(path: directory), withIntermediateDirectories: true)
        }
        for file in ["extension-commands.json", "extension-versions.json", "PluginData/demo.json"] {
            try Data("{}".utf8).write(to: support.appending(path: file))
        }
        let suite = "RaycastExtensionsMigrationTests.\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in RaycastExtensionsMigration.defaultsKeys { defaults.set(true, forKey: key) }
        defaults.set("{}", forKey: "hotkey.extensionCommand.extension:demo/search")
        defaults.set("{}", forKey: "hotkey.togglePalette")
        defaults.set("{}", forKey: "hotkey.pluginCommand.plugin:demo/search")
        defaults.set(true, forKey: "pluginsEnabled")
        let favorites = Keys(["extension:demo/search", "app:com.apple.Safari", "plugin:demo/search"])
        let aliases = Keys(["extension:demo/other"])

        RaycastExtensionsMigration.run(
            entryKeys: [favorites.store, aliases.store], defaults: defaults, support: support,
            settingsFile: support.appending(path: "settings.json"))

        for item in RaycastExtensionsMigration.supportItems {
            expect(!files.fileExists(atPath: support.appending(path: item).path), "\(item) is deleted")
        }
        expect(
            files.fileExists(atPath: support.appending(path: "PluginData/demo.json").path),
            "plugin data stays")
        for key in RaycastExtensionsMigration.defaultsKeys {
            expect(defaults.object(forKey: key) == nil, "\(key) is removed")
        }
        expect(
            defaults.object(forKey: "hotkey.extensionCommand.extension:demo/search") == nil,
            "an extension command's shortcut is removed")
        expect(defaults.object(forKey: "hotkey.togglePalette") != nil, "the palette's shortcut stays")
        expect(
            defaults.object(forKey: "hotkey.pluginCommand.plugin:demo/search") != nil,
            "a plugin's shortcut stays")
        expect(defaults.bool(forKey: "pluginsEnabled"), "the plugins switch stays")
        expect(
            favorites.keys == ["app:com.apple.Safari", "plugin:demo/search"],
            "only extension rows leave the favorites")
        expect(aliases.keys.isEmpty, "an extension command's alias goes")
        try? files.removeItem(at: support)
    }

    static func testSettingsFile() throws {
        print("settings.json")
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "settings.json")
        let kept = SettingsFileFormat.render([.calendarMenuBarHidesWhenEmpty: .bool(true)])
        let object = try require(JSONSerialization.jsonObject(with: kept) as? [String: Any])

        var retired = object
        retired["extensions"] = ["showInLauncher": false]
        try JSONSerialization.data(withJSONObject: retired).write(to: url)
        RaycastExtensionsMigration.run(
            entryKeys: [], defaults: scratchDefaults, support: folder, settingsFile: url)
        let rewritten = try Data(contentsOf: url)
        expect(rewritten == kept, "the retired section goes and the rest is written as Tinycast writes it")

        var mistaken = retired
        mistaken["calendar"] = ["menuBarHidesWhenEmpty": true, "menuBarHidesWhenEmty": true]
        let typo = try JSONSerialization.data(withJSONObject: mistaken)
        try typo.write(to: url)
        RaycastExtensionsMigration.run(
            entryKeys: [], defaults: scratchDefaults, support: folder, settingsFile: url)
        expect(try Data(contentsOf: url) == typo, "a file with another mistake is left for the user to see")
    }

    static func testNothingToDo() throws {
        print("Nothing to do")
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "settings.json")
        let clean = SettingsFileFormat.render([.calendarMenuBarHidesWhenEmpty: .bool(true)])
        try clean.write(to: url)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let favorites = Keys(["app:com.apple.Safari"])
        var removals = 0
        let counted = RaycastExtensionsMigration.EntryKeys(
            keys: { favorites.keys }, remove: { _ in removals += 1 })
        RaycastExtensionsMigration.run(
            entryKeys: [counted], defaults: scratchDefaults, support: folder, settingsFile: url)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        expect(before == after, "a clean settings.json is not rewritten")
        expect(removals == 0, "a store with no extension rows is not touched")
    }
}

enum RequireError: Error {
    case missing
}

func require<T>(_ value: T?) throws -> T {
    guard let value else { throw RequireError.missing }
    return value
}
