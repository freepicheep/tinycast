import _TinycastHost

/// Where a plugin's `main.swift` names its commands, by the names `plugin.json` gives them.
public enum Plugin {
    /// A command that opens a screen: `Plugin.command("world-clock") { WorldClock() }`.
    public static func command<Content: View>(_ name: String, _ content: @escaping () -> Content) {
        // Made once per launch, so the view's `@State` lasts across renders.
        _views[name] = {
            let view = content()
            return { _resolve(view) }
        }
    }

    /// A command that does its work and closes the palette.
    public static func action(_ name: String, _ run: @escaping () async throws -> Void) {
        _actions[name] = run
    }

    /// The name of the command that is running.
    public static var commandName: String { _environment?.commandName ?? "" }
}

/// Shows a short message after the palette closes.
public func showHUD(_ text: String) {
    _environment?.showHUD(text)
}

public func closeWindow() {
    _environment?.closeWindow()
}

/// Opens a web address or a file path with its default app.
public func open(_ destination: String) {
    _environment?.open(destination)
}

public func copyToClipboard(_ text: String) {
    _environment?.copy(text)
}

/// Pastes into the app that was frontmost before the palette opened.
public func paste(_ text: String) {
    _environment?.paste(text)
}

/// Leaves the screen a `NavigationLink` pushed.
public func dismiss() {
    _ = _tinycastPop()
}

// MARK: - The session, as Tinycast drives it

var _environment: PluginEnvironment? = nil
var _views: [String: () -> () -> [_Element]] = [:]
var _actions: [String: () async throws -> Void] = [:]
var _stack: [_Entry] = []

/// One screen on the command's stack. A class, so the views it made keep their state.
final class _Entry {
    let render: () -> [_Element]
    var task: Task<Void, Never>?
    var taskKey: String?

    init(_ render: @escaping () -> [_Element]) {
        self.render = render
    }
}

func _push(_ entry: _Entry) {
    _stack.append(entry)
    _environment?.invalidate()
}

func _tinycastBegin(_ environment: PluginEnvironment) {
    _environment = environment
}

func _tinycastCommands() -> [String] {
    Array(_views.keys) + Array(_actions.keys)
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

func _tinycastDepth() -> Int { _stack.count }

func _tinycastPop() -> Bool {
    guard _stack.count > 1 else { return false }
    _stack.removeLast().task?.cancel()
    _environment?.invalidate()
    return true
}

func _tinycastEnd() {
    for entry in _stack { entry.task?.cancel() }
    _stack = []
    _environment = nil
}

/// The top of the stack as Tinycast draws it; starts the screen's `task` the first time.
func _tinycastRender() -> PluginPage {
    guard let entry = _stack.last else { return .list(_emptyList([])) }
    let elements = entry.render()
    for element in elements {
        switch element {
        case .list(let list, let task):
            _start(task, in: entry)
            return .list(list)
        case .detail(let detail, let task):
            _start(task, in: entry)
            return .detail(detail)
        default:
            continue
        }
    }
    return .list(_emptyList(elements))
}

func _start(_ task: _Task?, in entry: _Entry) {
    guard let task, entry.taskKey != task.key else { return }
    entry.task?.cancel()
    entry.taskKey = task.key
    let run = task.run
    entry.task = Task { await run() }
}

/// A `body` of bare rows, with no `List` around them, still shows as one.
func _emptyList(_ elements: [_Element]) -> PluginList {
    var items: [PluginItem] = []
    var sections: [PluginSection] = []
    for element in elements {
        if case .item(let item) = element { items.append(item) }
        if case .section(let section) = element { sections.append(section) }
    }
    if !items.isEmpty { sections.insert(PluginSection(title: nil, items: items), at: 0) }
    return PluginList(
        title: nil, searchPrompt: nil, search: nil, isLoading: false, emptyText: nil,
        emptySymbol: nil, sections: sections)
}
