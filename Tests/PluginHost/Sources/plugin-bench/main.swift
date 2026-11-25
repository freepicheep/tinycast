import Darwin
import Foundation
import Scrift

// Measures one command the way the palette runs it: a fresh runtime per launch, launched, waited on
// until its content shows (a view) or it ends (an action), then stopped and shut down.
// Scripts/bench-plugins.sh runs each case in its own process, alternating where it runs, and
// summarizes.
//
//     plugin-bench <scrift|helper> <directory> <command> <iterations> [cache directory]
//
// `helper` runs the runtime in the plugin helper next to this binary, as the app does: the numbers
// then include the pipe, and `helper_footprint` is the helper's own memory.
// Prints one JSON line per launch, then one for the process. A view is done once its frame shows
// BENCH_NEEDLE, or BENCH_ITEMS rows (default 1); BENCH_PREFS is JSON preferences, BENCH_TIMEOUT
// seconds bounds a launch, BENCH_SETTLE_MS is the pause after one, BENCH_DUMP prints each last frame.

// MARK: - Process measurements

struct Footprint {
    let current: Int
    let peak: Int
}

func footprint() -> Footprint {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return Footprint(current: Int(info.phys_footprint), peak: Int(info.ledger_phys_footprint_peak))
}

/// User plus system CPU time of every thread in the process, in seconds.
func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

func threadCount() -> Int {
    var threads: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
    for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[index]) }
    vm_deallocate(
        mach_task_self_, vm_address_t(bitPattern: threads),
        vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
    return Int(count)
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

// MARK: - Host

/// Canned answers for everything that would reach the desktop.
@MainActor
final class BenchHost: PluginHostAPI {
    var log: [String] = []

    func perform(_ call: PluginHostCall) async throws -> PluginHostAnswer {
        log.append("\(call)")
        switch call {
        case .selectedText: return .text("Good morning")
        case .showToast: return .int(1)
        case .confirm: return .bool(true)
        case .applications: return .applications([])
        case .frontmostApplication:
            return .application(
                PluginApplication(
                    name: "Finder", path: "/System/Library/CoreServices/Finder.app", bundleID: "com.apple.finder"))
        default: return .none
        }
    }

    func sessionEnded() {}
}

/// Each frame as the pipe and the palette get it: its JSON, and how long encoding it took.
@MainActor
final class Recorder: PluginRuntimeDelegate {
    var frame: PluginFrame?
    var renders = 0
    var firstRender: ContinuousClock.Instant?
    var frameBytes: [Int] = []
    var encodeSeconds: [Double] = []
    var json = ""
    var failure: String?
    var finished = false
    private let encoder = JSONEncoder()

    func runtime(_ runtime: any PluginRuntime, session: String, didRender frame: PluginFrame) {
        if firstRender == nil { firstRender = .now }
        self.frame = frame
        renders += 1
        let started = ContinuousClock.now
        let data = (try? encoder.encode(frame)) ?? Data()
        encodeSeconds.append(seconds(ContinuousClock.now - started))
        frameBytes.append(data.count)
        json = String(decoding: data, as: UTF8.self)
    }
    func runtime(_ runtime: any PluginRuntime, session: String, didFail message: String) { failure = message }
    func runtime(_ runtime: any PluginRuntime, session: String, didFinish: Void) { finished = true }
}

func rows(in frame: PluginFrame) -> Int {
    switch frame.screen {
    case .list(let list): list.sections.reduce(0) { $0 + $1.rows.count }
    case .grid(let grid): grid.sections.reduce(0) { $0 + $1.rows.count }
    case .menuBar(let menu): menu.items.count
    case .form(let form): form.fields.count
    case .detail: 1
    case .unsupported: 0
    }
}

// MARK: - The command

let benchRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
let repository = benchRoot.appending(path: "../..").standardized

/// One command, ready to launch any number of times.
@MainActor
struct Subject {
    let manifest: PluginManifest
    let directory: URL
    let command: PluginCommand
    let kit: PluginSources
    let cache: ScriftModuleCache
    let storage = PluginMemoryStorage()
    let preferences: [String: PluginValue]
    let helper: PluginHelperClient?

    init(
        directory: URL, command name: String, cache: ScriftModuleCache, manifestCache: URL?,
        preferences overrides: [String: PluginValue], helper: PluginHelperClient? = nil
    ) throws {
        self.helper = helper
        let description = try PluginSources.read(
            from: repository.appending(path: "Tinycast/Resources/PluginDescription"), requiringMain: false)
        kit = try PluginSources.read(from: repository.appending(path: "Tinycast/Resources/PluginKit"), requiringMain: false)
        let text = try String(contentsOf: directory.appending(path: "Manifest.swift"), encoding: .utf8)
        // As the catalog reads it: from its cache once it has run, so an unchanged manifest doesn't run.
        manifest = try PluginManifestReader.read(text, description: description, cache: manifestCache).manifest.get()
        guard let command = manifest.commands.first(where: { $0.name == name }) else {
            throw PluginSessionError.internal("no command \(name)")
        }
        self.directory = directory
        self.command = command
        self.cache = cache
        var preferences: [String: PluginValue] = [:]
        for preference in manifest.preferences + (command.preferences ?? []) {
            if let value = preference.defaultValue { preferences[preference.name] = value }
        }
        self.preferences = preferences.merging(overrides) { $1 }
    }

    func makeRuntime(host: BenchHost) -> any PluginRuntime {
        if let helper {
            return RemotePluginRuntime(
                client: helper, plugin: manifest, directory: directory, storage: storage, hostAPI: host,
                appScheme: "tinycast", kitDirectory: repository.appending(path: "Tinycast/Resources/PluginKit"))
        }
        let kit = kit
        return ScriftPluginRuntime(
            plugin: manifest, directory: directory, storage: storage, hostAPI: host, appScheme: "tinycast",
            moduleCache: cache, kitSources: { kit })
    }

    func launch(_ runtime: any PluginRuntime, session: String) async throws {
        let launch = PluginLaunch(
            commandName: command.name, isBackground: false, arguments: [:], preferences: preferences,
            fallbackText: nil, launchContext: [:], isDarkAppearance: false)
        try await runtime.launch(session: session, launch: launch)
    }
}

// MARK: - The run

/// When a launch counts as done: a view once its frame shows `needle` or `items` rows, an action
/// once it finishes.
struct Goal {
    var needle: String?
    var items = 1
}

func environmentPreferences() -> [String: PluginValue] {
    guard let raw = ProcessInfo.processInfo.environment["BENCH_PREFS"],
        let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
    else { return [:] }
    return json.compactMapValues { value in
        if let flag = value as? Bool { return PluginValue.bool(flag) }
        if let text = value as? String { return PluginValue.string(text) }
        return nil
    }
}

func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

@MainActor
func bench() async {
    let arguments = CommandLine.arguments
    guard arguments.count >= 5, let iterations = Int(arguments[4]) else {
        print("usage: plugin-bench <scrift|helper> <directory> <command> <iterations> [cache directory]")
        exit(2)
    }
    let engine = arguments[1]
    let directory = URL(filePath: arguments[2])
    let environment = ProcessInfo.processInfo.environment
    var goal = Goal()
    goal.needle = environment["BENCH_NEEDLE"]
    goal.items = environment["BENCH_ITEMS"].flatMap(Int.init) ?? 1
    let timeout = Duration.seconds(environment["BENCH_TIMEOUT"].flatMap(Int.init) ?? 15)

    // Before anything engine-related: setup (a plugin's manifest runs here) counts separately.
    try? await Task.sleep(for: .milliseconds(200))
    let processBaseline = footprint()
    let setupStarted = ContinuousClock.now
    let setupCPU = cpuSeconds()
    let subject: Subject
    var helper: PluginHelperClient?
    do {
        let cacheDirectory = arguments.count > 5 ? URL(filePath: arguments[5]) : nil
        if engine == "helper" {
            helper = PluginHelperClient(
                executable: Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "plugin-helper"),
                cacheDirectory: cacheDirectory
                    ?? FileManager.default.temporaryDirectory.appending(path: "plugin-bench-cache-\(UUID())"))
        }
        subject = try Subject(
            directory: directory, command: arguments[3], cache: ScriftModuleCache(directory: cacheDirectory),
            manifestCache: cacheDirectory?.appending(path: "Manifests"), preferences: environmentPreferences(),
            helper: helper)
    } catch {
        print("setup failed: \(error)")
        exit(1)
    }

    let setupTime = seconds(ContinuousClock.now - setupStarted)
    let setupCPUTime = cpuSeconds() - setupCPU
    try? await Task.sleep(for: .milliseconds(200))
    let baseline = footprint()
    let baselineThreads = threadCount()
    var maxThreads = baselineThreads

    for iteration in 0..<iterations {
        let host = BenchHost()
        let recorder = Recorder()
        let before = footprint().current
        let cpuBefore = cpuSeconds()
        let started = ContinuousClock.now

        let runtime = subject.makeRuntime(host: host)
        runtime.setDelegate(recorder)
        let session = "bench-\(iteration)"
        var launchError: String?
        do {
            try await subject.launch(runtime, session: session)
        } catch {
            launchError = "\(error)"
        }
        let launched = ContinuousClock.now

        // Checked only when something changed, so waiting costs next to nothing.
        var checkedRenders = -1
        var reachedGoal = false
        func done() -> Bool {
            if recorder.failure != nil || launchError != nil { return true }
            if subject.command.mode == .action { return recorder.finished }
            if recorder.renders != checkedRenders {
                checkedRenders = recorder.renders
                reachedGoal = goalReached()
            }
            return reachedGoal
        }
        func goalReached() -> Bool {
            guard let frame = recorder.frame else { return false }
            if let needle = goal.needle { return recorder.json.localizedCaseInsensitiveContains(needle) }
            return rows(in: frame) >= goal.items
        }
        var polls = 0
        while !done(), ContinuousClock.now - started < timeout {
            polls += 1
            if polls % 20 == 0 { maxThreads = max(maxThreads, threadCount()) }
            try? await Task.sleep(for: .milliseconds(1))
        }
        if subject.command.mode == .action { await runtime.drainHostCalls() }
        let ended = ContinuousClock.now
        let cpuDone = cpuSeconds()
        let atContent = footprint().current
        maxThreads = max(maxThreads, threadCount())
        let reached = done() && recorder.failure == nil && launchError == nil
        if environment["BENCH_DUMP"] != nil { print("DUMP \(recorder.json) \(host.log.suffix(6))") }

        await runtime.stop(session: session)
        runtime.shutdown()
        // Let queued teardown and the engines' collectors run before measuring what stayed.
        try? await Task.sleep(for: .milliseconds(environment["BENCH_SETTLE_MS"].flatMap(Int.init) ?? 500))
        let after = footprint().current

        emit([
            "engine": engine, "command": subject.command.name, "iteration": iteration, "ok": reached,
            "failure": recorder.failure ?? launchError ?? (reached ? "" : "timed out"),
            "launch_s": seconds(launched - started),
            "first_render_s": recorder.firstRender.map { seconds($0 - started) } ?? -1,
            "content_s": seconds(ended - started),
            "cpu_s": cpuDone - cpuBefore,
            "renders": recorder.renders,
            "frame_bytes": recorder.frameBytes.last ?? 0,
            "frame_bytes_max": recorder.frameBytes.max() ?? 0,
            "encode_s": recorder.encodeSeconds.max() ?? 0,
            "footprint_during": atContent - before,
            "footprint_retained": after - baseline.current,
            "helper_footprint": helper?.footprint ?? 0,
        ])
    }
    let end = footprint()
    emit([
        "engine": engine, "command": subject.command.name, "summary": true,
        "process_footprint": processBaseline.current, "setup_footprint": baseline.current - processBaseline.current,
        "setup_s": setupTime, "setup_cpu_s": setupCPUTime,
        "peak_over_baseline": end.peak - baseline.current, "retained_after_all": end.current - baseline.current,
        "baseline_threads": baselineThreads, "max_threads": maxThreads,
    ])
    exit(0)
}

setvbuf(stdout, nil, _IONBF, 0)
Task { @MainActor in await bench() }
RunLoop.main.run()
