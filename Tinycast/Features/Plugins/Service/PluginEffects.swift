import AppKit
import Foundation

/// What the app does for a plugin on the desktop: the clipboard, opening, Finder, applications and
/// the selection. Grants are checked before these are called.
@MainActor
enum PluginEffects {
    static func copy(_ text: String, concealed: Bool) {
        guard concealed else {
            Paster.copyPlainText(text)
            return
        }
        // Clipboard managers, this app's history included, skip what carries this type.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealedType], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: concealedType)
    }

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static func open(_ url: URL, application: String?) {
        guard let application, let app = applicationURL(application) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open(
            [url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    /// A path, a bundle identifier or an application's name.
    private static func applicationURL(_ application: String) -> URL? {
        if application.hasPrefix("/") { return URL(filePath: application) }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: application) { return url }
        let candidate = URL(filePath: "/Applications/\(application).app")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    static func reveal(_ path: String) {
        AppLauncher.showInFinder(fileURL(path))
    }

    static func trash(_ paths: [String]) {
        for path in paths { try? FileManager.default.trashItem(at: fileURL(path), resultingItemURL: nil) }
    }

    static func fileURL(_ path: String) -> URL {
        URL(filePath: (path as NSString).expandingTildeInPath)
    }

    static func applications(forPath path: String?, all: [URL]) -> [PluginApplication] {
        guard let path, !path.isEmpty else { return all.map(describe) }
        return NSWorkspace.shared.urlsForApplications(toOpen: fileURL(path)).map(describe)
    }

    static func defaultApplication(for target: String) -> PluginApplication? {
        let url = URL(string: target).flatMap { $0.scheme == nil ? nil : $0 } ?? fileURL(target)
        return NSWorkspace.shared.urlForApplication(toOpen: url).map(describe)
    }

    static func describe(_ application: URL) -> PluginApplication {
        let bundle = Bundle(url: application)
        return PluginApplication(
            name: bundle?.installedAppName ?? application.deletingPathExtension().lastPathComponent,
            path: application.path, bundleID: bundle?.bundleIdentifier)
    }

    /// In the app the palette displaced, never this one.
    static func selectedText(in target: NSRunningApplication?) -> String? {
        guard Permissions.ensureAccessibility(), let target,
            target.processIdentifier != NSRunningApplication.current.processIdentifier
        else { return nil }
        return AccessibilityText.selection(in: target)
    }

    /// Joined on a linefeed, which Finder forbids in a name.
    static func finderSelection() -> [String] {
        let script = """
            set AppleScript's text item delimiters to linefeed
            tell application "Finder" to set chosen to (get selection as alias list)
            set paths to {}
            repeat with one in chosen
                set end of paths to POSIX path of one
            end repeat
            return paths as text
            """
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        guard error == nil else { return [] }
        return result?.stringValue?.split(separator: "\n").map(String.init) ?? []
    }
}
