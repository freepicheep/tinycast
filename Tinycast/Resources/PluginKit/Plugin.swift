// The `Tinycast` module every plugin imports, run by Scrift; the app never compiles this file.

import Foundation
import _TinycastHost

/// Where a plugin's `main.swift` gives its commands their code, by the names `Manifest.swift` declares.
public enum Plugin {
    /// A command that opens a screen: `Plugin.command("world-clock") { WorldClock() }`.
    public static func command<Content: View>(_ name: String, _ content: @escaping () -> Content) {
        _registrations[name] = "view"
        // Made once per launch, so the view's `@State` lasts across renders.
        _views[name] = {
            let view = content()
            return { _resolve(view) }
        }
    }

    /// A command that does its work and closes the palette, and may run again in the background
    /// when its manifest gives it an `interval`.
    public static func action(_ name: String, _ run: @escaping () async throws -> Void) {
        _registrations[name] = "action"
        _actions[name] = run
    }

    /// A menu-bar command: its body is a `MenuBarExtra`.
    public static func menuBar<Content: View>(_ name: String, _ content: @escaping () -> Content) {
        _registrations[name] = "menuBar"
        _views[name] = {
            let view = content()
            return { _resolve(view) }
        }
    }

    /// The name of the command that is running.
    public static var commandName: String { _launch?.commandName ?? "" }

    /// What the launcher's argument fields held; every declared argument is here, empty when unfilled.
    public static var arguments: [String: String] { _launch?.arguments ?? [:] }

    /// The text typed in the launcher when the command ran from a fallback search, if any.
    public static var fallbackText: String? { _launch?.fallbackText }

    /// What `launchCommand(_:context:)` passed, or a deep link's `context`.
    public static var launchContext: [String: PluginValue] { _launch?.launchContext ?? [:] }

    /// Every preference's value, by name; `@Preference` reads one typed.
    public static var preferences: [String: PluginValue] { _launch?.preferences ?? [:] }

    /// Whether the user ran the command or its schedule did.
    public static var launchType: LaunchType { (_launch?.isBackground ?? false) ? .background : .userInitiated }
}

public enum LaunchType {
    case userInitiated
    case background
}

// MARK: - The session, as Tinycast drives it

var _environment: PluginEnvironment? = nil
var _launch: PluginLaunch? = nil
var _registrations: [String: String] = [:]
var _views: [String: () -> () -> [_Part]] = [:]
var _actions: [String: () async throws -> Void] = [:]
var _stack: [_Entry] = []

/// One screen on the command's stack. A class, so the views it made keep their state.
final class _Entry {
    let render: () -> [_Part]
    var task: Task<Void, Never>?
    var taskKey: String?

    init(_ render: @escaping () -> [_Part]) {
        self.render = render
    }
}

func _push(_ entry: _Entry) {
    _stack.append(entry)
    _environment?.invalidate()
}

func _tinycastRegistrations() -> [String: String] { _registrations }

func _tinycastBegin(_ environment: PluginEnvironment, _ launch: PluginLaunch) {
    _environment = environment
    _launch = launch
}

/// False when `main.swift` registered no screen by that name.
func _tinycastOpen(_ name: String) -> Bool {
    guard let make = _views[name] else { return false }
    _stack = [_Entry(make())]
    return true
}

func _tinycastRun(_ name: String) async throws -> Bool {
    guard let run = _actions[name] else { return false }
    try await run()
    return true
}

func _tinycastPop() -> Bool {
    guard _stack.count > 1 else { return false }
    _stack.removeLast().task?.cancel()
    _environment?.invalidate()
    return true
}

func _tinycastEnd() {
    for entry in _stack { entry.task?.cancel() }
    _stack = []
    _tables = []
    _environment = nil
}

func _start(_ task: _Task?, in entry: _Entry) {
    guard let task, entry.taskKey != task.key else { return }
    entry.task?.cancel()
    entry.taskKey = task.key
    let run = task.run
    entry.task = Task { await run() }
}

// MARK: - What every command can ask of Tinycast

/// Closes the palette; the command keeps running until it returns.
public func closeMainWindow(clearRootSearch: Bool = false) {
    _environment?.closeMainWindow(clearRootSearch: clearRootSearch)
}

/// Back to the command's first screen.
public func popToRoot() {
    _environment?.popToRoot()
}

public func clearSearchBar() {
    _environment?.clearSearchBar()
}

/// Settings › Plugins, at this plugin.
public func openPreferences() {
    _environment?.openPreferences()
}

/// Opens a web address, a file path, or an app link the manifest allows, optionally with
/// `application` (a name, bundle id or path).
public func open(_ destination: String, application: String? = nil) {
    _environment?.open(destination, application: application)
}

public func showInFinder(_ path: String) {
    _environment?.showInFinder(path)
}

/// Runs another of this plugin's commands, with arguments and a context it reads as
/// `Plugin.arguments` and `Plugin.launchContext`.
public func launchCommand(
    _ name: String, type: LaunchType = .userInitiated, arguments: [String: String] = [:],
    context: [String: PluginValue] = [:]
) async throws {
    try await _environment?.launchCommand(
        name, background: type == .background, arguments: arguments, context: context)
}

/// Changes the running command's subtitle in the launcher; nil puts back the manifest's.
public func updateCommandMetadata(subtitle: String?) {
    _environment?.updateCommandMetadata(subtitle: subtitle)
}

/// An installed application.
public typealias Application = PluginApplication

/// The applications the launcher lists, or those that open `path`.
public func getApplications(_ path: String? = nil) async throws -> [Application] {
    try await _environment?.applications(forPath: path) ?? []
}

public func getDefaultApplication(_ path: String) async throws -> Application? {
    try await _environment?.defaultApplication(for: path)
}

/// The app that was in front before the palette opened.
public func getFrontmostApplication() async throws -> Application? {
    try await _environment?.frontmostApplication()
}
