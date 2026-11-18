// How Tinycast drives a plugin: the module's exports, the executor Swift concurrency runs on, host
// calls and timers. Plugins never call anything here by name.

@_spi(ExperimentalCustomExecutors) @_spi(ExperimentalScheduling) import _Concurrency
import CTinycastKit

// MARK: - The executor: jobs wait in a queue the kit drains before every export returns

// One thread, so no lock: the executor is reached from jobs on either executor and from exports.
nonisolated(unsafe) var _readyJobs: [(job: UnownedJob, onMain: Bool)] = []
nonisolated(unsafe) var _timers: [UInt32: () -> Void] = [:]
nonisolated(unsafe) var _nextToken: UInt32 = 1

/// The instance has one thread, so the main executor and the default one share it: a job enqueued
/// on either waits in `_readyJobs` until the export running now drains it.
nonisolated final class _KitExecutor: MainExecutor, TaskExecutor, SchedulingExecutor, @unchecked Sendable {
    let onMain: Bool

    init(onMain: Bool) { self.onMain = onMain }

    func enqueue(_ job: consuming ExecutorJob) {
        _readyJobs.append((UnownedJob(job), onMain))
    }

    func enqueue<C: Clock>(
        _ job: consuming ExecutorJob, after delay: C.Duration, tolerance: C.Duration?, clock: C
    ) {
        let job = UnownedJob(job)
        let onMain = onMain
        let milliseconds = (delay as? Duration).map(Self.milliseconds) ?? 0
        let token = _nextToken
        _nextToken &+= 1
        _timers[token] = { _readyJobs.append((job, onMain)) }
        tinycast_set_timer(token, milliseconds)
    }

    func enqueue<C: Clock>(
        _ job: consuming ExecutorJob, at instant: C.Instant, tolerance: C.Duration?, clock: C
    ) {
        enqueue(job, after: clock.now.duration(to: instant), tolerance: tolerance, clock: clock)
    }

    func run() throws {}
    func stop() {}

    private static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return max(Double(seconds) * 1000 + Double(attoseconds) / 1e15, 0)
    }
}

nonisolated let _mainExecutor = _KitExecutor(onMain: true)
nonisolated let _defaultExecutor = _KitExecutor(onMain: false)

nonisolated struct _KitExecutors: ExecutorFactory {
    static var mainExecutor: any MainExecutor { _mainExecutor }
    static var defaultExecutor: any TaskExecutor { _defaultExecutor }
}

nonisolated func _drain() {
    while !_readyJobs.isEmpty {
        let (job, onMain) = _readyJobs.removeFirst()
        if onMain {
            job.runSynchronously(on: _mainExecutor.asUnownedSerialExecutor())
        } else {
            job.runSynchronously(on: _defaultExecutor.asUnownedTaskExecutor())
        }
    }
}

// MARK: - Bytes across the boundary

/// Takes the buffer the host filled through `tinycast_alloc`, and frees it.
nonisolated func _take(_ pointer: UnsafeMutableRawPointer?, _ length: Int32) -> String {
    guard let pointer else { return "" }
    defer { pointer.deallocate() }
    return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(length)), as: UTF8.self)
}

nonisolated func _withUTF8<R>(_ text: String, _ body: (UnsafePointer<UInt8>?, Int) -> R) -> R {
    var text = text
    return text.withUTF8 { body($0.baseAddress, $0.count) }
}

// MARK: - Host calls

/// What a host API threw, with its message.
public nonisolated struct HostError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

@MainActor var _pendingCalls: [UInt32: CheckedContinuation<PluginValue, any Error>] = [:]

/// One of the Extensions host's APIs, as Raycast's own runtime calls it; the answer is its JSON.
@MainActor
func _call(_ api: String, _ method: String, _ arguments: [PluginValue]) async throws -> PluginValue {
    let request = PluginValue.object([
        "api": .string(api), "method": .string(method), "args": .array(arguments)
    ]).json
    return try await withCheckedThrowingContinuation { continuation in
        let id = _nextToken
        _nextToken &+= 1
        _pendingCalls[id] = continuation
        _withUTF8(request) { tinycast_call(id, $0, $1) }
    }
}

/// Fire and forget: a failure is the command's, shown in place of its screen.
@MainActor
func _send(_ api: String, _ method: String, _ arguments: [PluginValue]) {
    Task { @MainActor in
        do {
            _ = try await _call(api, method, arguments)
        } catch {
            _fail(error)
        }
    }
}

// MARK: - The session

@MainActor var _session: UInt32 = 0
@MainActor var _started = false
@MainActor var _plugin: (any Plugin)?
@MainActor var _commands: [String: Command] = [:]
@MainActor var _launch: _Launch?
@MainActor var _handlers: [String: _Handler] = [:]
@MainActor var _invalidated = false
@MainActor var _reportedDepth = 0
/// A no-view command, or a handler that completes the session: it finishes once nothing waits.
@MainActor var _finishWhenIdle = false
@MainActor var _ended = false

typealias _Handler = @MainActor ([PluginValue]) throws -> Void

/// What the host passed at launch, decoded once.
struct _Launch {
    var commandName = ""
    var launchType = "userInitiated"
    var arguments: [String: String] = [:]
    var fallbackText: String?
    var launchContext: [String: PluginValue] = [:]
    var preferences: [String: PluginValue] = [:]
    var caches: [String: [String: String]] = [:]
    var formValues: [String: String] = [:]
    var localStorage: [String: PluginValue] = [:]
    var isDarkAppearance = false
    /// Tinycast's own URL scheme, where an OAuth sign-in comes back.
    var appScheme = "tinycast"
}

/// The plugin's `@main` type runs this: it registers the plugin, so its manifest and commands are
/// what the host reads.
@MainActor
public func _register(_ plugin: some Plugin) {
    _plugin = plugin
    _commands = [:]
    for command in plugin.commands { _commands[command.name] = command }
}

@MainActor func _start() {
    guard !_started else { return }
    _started = true
    _createExecutors(factory: _KitExecutors.self)
    tinycast_run_main()
    _drain()
}

/// A `@State` changed: the screen renders again before the export returns.
@MainActor func _invalidate() { _invalidated = true }

@MainActor func _fail(_ error: any Error) {
    let message: String
    switch error {
    case let error as HostError: message = error.message
    case let error as CustomStringConvertible: message = "The command threw an error: \(error.description)"
    default: message = "The command threw an error: \(String(reflecting: error))"
    }
    _fail(message)
}

@MainActor func _fail(_ message: String) {
    guard !_ended else { return }
    _end()
    _withUTF8(message) { tinycast_failed(_session, $0, $1) }
}

@MainActor func _end() {
    _ended = true
    for entry in _stack { entry.task?.cancel() }
    _stack = []
    _handlers = [:]
    _finishWhenIdle = false
}

/// After every export: run what became ready, draw what changed, and finish an idle no-view run.
@MainActor func _settle() {
    _drain()
    if _invalidated, !_ended, !_stack.isEmpty {
        _invalidated = false
        _renderNow()
        _drain()
    }
    if _finishWhenIdle, !_ended, _readyJobs.isEmpty, _pendingCalls.isEmpty, _timers.isEmpty,
        _runningActions == 0
    {
        _ended = true
        _finishWhenIdle = false
        tinycast_finished(_session)
    }
}

@MainActor var _runningActions = 0

@MainActor func _renderNow() {
    let json = _tree()
    _withUTF8(json) { tinycast_render(_session, $0, $1) }
    let depth = max(_stack.count, 1)
    if depth != _reportedDepth {
        _reportedDepth = depth
        tinycast_navigation(_session, UInt32(depth))
    }
}

// MARK: - Exports

@_expose(wasm, "tinycast_alloc")
@_cdecl("tinycast_alloc")
public nonisolated func _tinycastAlloc(_ length: Int32) -> UnsafeMutableRawPointer {
    .allocate(byteCount: Int(max(length, 1)), alignment: 8)
}

/// Calls the host's `manifest` import with the plugin's manifest JSON.
@_expose(wasm, "tinycast_describe")
@_cdecl("tinycast_describe")
public nonisolated func _tinycastDescribe() {
    MainActor.assumeIsolated {
        _start()
        let json = _plugin.map { _manifestJSON($0) } ?? "{}"
        _withUTF8(json) { tinycast_manifest($0, $1) }
    }
}

@_expose(wasm, "tinycast_launch")
@_cdecl("tinycast_launch")
public nonisolated func _tinycastLaunch(
    _ session: UInt32, _ command: UnsafeMutableRawPointer?, _ commandLength: Int32,
    _ launch: UnsafeMutableRawPointer?, _ launchLength: Int32
) {
    let name = _take(command, commandLength)
    let payload = _take(launch, launchLength)
    MainActor.assumeIsolated {
        _start()
        _session = session
        _ended = false
        _launch = _Launch(json: PluginValue(json: payload), command: name)
        guard let command = _commands[name] else {
            return _fail("The plugin has no command named “\(name)”.")
        }
        switch command.body {
        case .view(let make):
            let render = make()
            _stack = [_Entry(render)]
            _renderNow()
        case .action(let run):
            _finishWhenIdle = true
            _runningActions += 1
            Task { @MainActor in
                defer { _runningActions -= 1 }
                do {
                    try await run()
                } catch {
                    _fail(error)
                }
            }
        }
        _settle()
    }
}

@_expose(wasm, "tinycast_dispatch")
@_cdecl("tinycast_dispatch")
public nonisolated func _tinycastDispatch(
    _ handler: UnsafeMutableRawPointer?, _ handlerLength: Int32,
    _ payload: UnsafeMutableRawPointer?, _ payloadLength: Int32, _ completes: Int32
) {
    let id = _take(handler, handlerLength)
    let json = _take(payload, payloadLength)
    MainActor.assumeIsolated {
        if completes != 0 { _finishWhenIdle = true }
        if let body = _handlers[id], !_ended {
            let arguments: [PluginValue]
            if case .array(let values) = PluginValue(json: json) { arguments = values } else { arguments = [] }
            do {
                try body(arguments)
            } catch {
                _fail(error)
            }
        }
        _settle()
    }
}

/// 1 when a pushed screen was popped.
@_expose(wasm, "tinycast_pop")
@_cdecl("tinycast_pop")
public nonisolated func _tinycastPop() -> Int32 {
    MainActor.assumeIsolated {
        let popped = _pop()
        _settle()
        return popped ? 1 : 0
    }
}

@_expose(wasm, "tinycast_stop")
@_cdecl("tinycast_stop")
public nonisolated func _tinycastStop() {
    MainActor.assumeIsolated {
        _end()
        _drain()
    }
}

@_expose(wasm, "tinycast_settle")
@_cdecl("tinycast_settle")
public nonisolated func _tinycastSettle(_ id: UInt32, _ ok: Int32, _ answer: UnsafeMutableRawPointer?, _ length: Int32) {
    let text = _take(answer, length)
    MainActor.assumeIsolated {
        if let continuation = _pendingCalls.removeValue(forKey: id) {
            if ok != 0 {
                continuation.resume(returning: PluginValue(json: text))
            } else {
                continuation.resume(throwing: HostError(message: text))
            }
        }
        _settle()
    }
}

@_expose(wasm, "tinycast_timer")
@_cdecl("tinycast_timer")
public nonisolated func _tinycastTimer(_ token: UInt32) {
    MainActor.assumeIsolated {
        _timers.removeValue(forKey: token)?()
        _settle()
    }
}

@_expose(wasm, "tinycast_toast_action")
@_cdecl("tinycast_toast_action")
public nonisolated func _tinycastToastAction(_ token: UnsafeMutableRawPointer?, _ length: Int32) {
    let key = _take(token, length)
    MainActor.assumeIsolated {
        if let action = _toastActions[key], !_ended { action() }
        _settle()
    }
}

extension _Launch {
    init(json: PluginValue, command: String) {
        self.init()
        commandName = command
        let fields = json.objectValue ?? [:]
        let props = fields["launchProps"]?.objectValue ?? [:]
        launchType = props["launchType"]?.text ?? "userInitiated"
        arguments = (props["arguments"]?.objectValue ?? [:]).compactMapValues(\.text)
        fallbackText = props["fallbackText"]?.text
        launchContext = props["launchContext"]?.objectValue ?? [:]
        preferences = fields["preferences"]?.objectValue ?? [:]
        caches = (fields["caches"]?.objectValue ?? [:]).mapValues {
            ($0.objectValue ?? [:]).compactMapValues(\.text)
        }
        formValues = (fields["formValues"]?.objectValue ?? [:]).compactMapValues(\.text)
        localStorage = fields["localStorage"]?.objectValue ?? [:]
        isDarkAppearance = fields["environment"]?.objectValue?["appearance"]?.text == "dark"
        appScheme = fields["appScheme"]?.text ?? "tinycast"
    }
}
