import Darwin
import Foundation
import Scrift

// Measures one command under one engine, the way the palette runs it: a fresh runtime per launch,
// booted, launched, waited on until its content shows (a view) or it ends (a no-view command),
// then stopped and shut down. Scripts/bench-plugins.sh runs each case in its own process,
// alternating engines, and summarizes.
//
//     plugin-bench <js|scrift> <directory> <command> <iterations> [cache directory]
//
// Prints one JSON line per launch, then one for the process. A view is done once it shows
// BENCH_NEEDLE, or BENCH_ITEMS items (default 1); BENCH_PREFS is JSON preferences, BENCH_TIMEOUT
// seconds bounds a launch, BENCH_SETTLE_MS is the pause after one, BENCH_DUMP prints each final screen.

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

/// The app's real fetch, canned answers for everything that would reach the desktop.
@MainActor
final class BenchHost: ExtensionHostAPI {
    var log: [String] = []
    private let fetcher = ExtensionFetcher()

    func perform(api: String, method: String, arguments: [RenderValue]) async throws -> String {
        log.append(api + "." + method)
        if api == "fetch" {
            return ExtensionJSON.string(from: try await fetcher.request(arguments.first))
        }
        switch api + "." + method {
        case "system.selectedText": return #""Good morning""#
        case "feedback.showToast": return "1"
        case "feedback.confirmAlert": return "true"
        case "storage.all": return "{}"
        case "storage.get", "clipboard.readText": return #""""#
        case "system.applications": return "[]"
        case "system.frontmostApplication":
            return #"{"name":"Finder","path":"/System/Library/CoreServices/Finder.app","bundleId":"com.apple.finder"}"#
        default: return ""
        }
    }

    func sessionEnded() {}
}

@MainActor
final class Recorder: ExtensionRuntimeDelegate {
    var tree: RenderTree?
    var renders = 0
    var firstRender: ContinuousClock.Instant?
    var failure: String?
    var finished = false

    func runtime(_ runtime: any ExtensionCommandRuntime, session: String, didRender tree: RenderTree) {
        self.tree = tree
        renders += 1
        if firstRender == nil { firstRender = .now }
    }
    func runtime(_ runtime: any ExtensionCommandRuntime, session: String, didFail message: String) {
        failure = message
    }
    func runtime(_ runtime: any ExtensionCommandRuntime, session: String, navigationDepth: Int) {}
    func runtime(_ runtime: any ExtensionCommandRuntime, session: String, didFinish: Void) { finished = true }
    func runtime(_ runtime: any ExtensionCommandRuntime, log level: String, message: String) {}
}

/// What the screen shows: its items, and whether any string in it has `needle`.
func items(in node: RenderNode) -> Int {
    (node.type.hasSuffix("Item") ? 1 : 0) + node.children.reduce(0) { $0 + items(in: $1) }
}

func contains(_ needle: String, in node: RenderNode) -> Bool {
    for value in node.props.values {
        if let text = value.stringValue, text.localizedCaseInsensitiveContains(needle) { return true }
        if value.nodesValue.contains(where: { contains(needle, in: $0) }) { return true }
    }
    return node.children.contains { contains(needle, in: $0) }
}

// MARK: - Engines

let benchRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
let repository = benchRoot.appending(path: "../..").standardized

/// One command, ready to launch any number of times.
@MainActor
protocol Subject {
    var command: ExtensionCommand { get }
    func makeRuntime(host: BenchHost) -> any ExtensionCommandRuntime
    func launch(_ runtime: any ExtensionCommandRuntime, session: String) async throws
}

@MainActor
struct JavaScriptSubject: Subject {
    let owner: InstalledExtension
    let command: ExtensionCommand
    let preferences: [String: ExtensionPreferenceValue]

    init(directory: URL, command name: String, preferences overrides: [String: ExtensionPreferenceValue]) throws {
        let manifest = try ExtensionManifest.load(directory: directory)
        guard let command = manifest.commands.first(where: { $0.name == name }) else {
            throw PluginSessionError.internal("no command \(name)")
        }
        owner = InstalledExtension(manifest: manifest, directory: directory)
        self.command = command
        var preferences: [String: ExtensionPreferenceValue] = [:]
        for schema in manifest.preferences + command.preferences {
            preferences[schema.name] = schema.effectiveDefault
        }
        self.preferences = preferences.merging(overrides) { $1 }
    }

    func makeRuntime(host: BenchHost) -> any ExtensionCommandRuntime {
        ExtensionRuntime(
            hostAPI: host, runtimeURL: repository.appending(path: "Tinycast/Resources/RaycastRuntime.generated.js"))
    }

    func launch(_ runtime: any ExtensionCommandRuntime, session: String) async throws {
        try await runtime.boot(config: .current(supportDirectory: FileManager.default.temporaryDirectory))
        let context = ExtensionLaunchContext(
            extensionName: owner.manifest.name, extensionTitle: owner.manifest.title, commandName: command.name,
            commandMode: command.mode, assetsPath: owner.directory.appending(path: "assets").path,
            supportPath: FileManager.default.temporaryDirectory.path, preferences: preferences, caches: [:],
            arguments: [:], isDarkAppearance: false)
        try await runtime.launch(session: session, owner: owner, command: command, context: context)
    }
}

@MainActor
struct ScriftSubject: Subject {
    let manifest: PluginManifest
    let directory: URL
    let owner: InstalledExtension
    let command: ExtensionCommand
    let kit: PluginSources
    let cache: ScriftModuleCache
    let storage: ExtensionStorage
    let preferences: [String: ExtensionPreferenceValue]

    init(
        directory: URL, command name: String, cache: ScriftModuleCache,
        preferences overrides: [String: ExtensionPreferenceValue]
    ) throws {
        let description = try PluginSources.read(
            from: repository.appending(path: "Tinycast/Resources/PluginDescription"), requiringMain: false)
        kit = try PluginSources.read(from: repository.appending(path: "Tinycast/Resources/PluginKit"), requiringMain: false)
        let text = try String(contentsOf: directory.appending(path: "Manifest.swift"), encoding: .utf8)
        manifest = try PluginManifestReader.evaluate(text, description: description).get()
        guard let extensionManifest = manifest.extensionManifest(),
            let command = extensionManifest.commands.first(where: { $0.name == name })
        else { throw PluginSessionError.internal("no command \(name)") }
        self.directory = directory
        owner = InstalledExtension(manifest: extensionManifest, directory: directory, engine: .plugin)
        self.command = command
        self.cache = cache
        storage = ExtensionStorage(
            directory: FileManager.default.temporaryDirectory.appending(path: "plugin-bench-storage-\(UUID())"))
        var preferences: [String: ExtensionPreferenceValue] = [:]
        for schema in extensionManifest.preferences + command.preferences {
            preferences[schema.name] = schema.effectiveDefault
        }
        self.preferences = preferences.merging(overrides) { $1 }
    }

    func makeRuntime(host: BenchHost) -> any ExtensionCommandRuntime {
        let kit = kit
        return ScriftPluginRuntime(
            plugin: manifest, directory: directory, storage: storage, hostAPI: host, appScheme: "tinycast",
            moduleCache: cache, kitSources: { kit })
    }

    func launch(_ runtime: any ExtensionCommandRuntime, session: String) async throws {
        try await runtime.boot(config: .current(supportDirectory: FileManager.default.temporaryDirectory))
        let context = ExtensionLaunchContext(
            extensionName: manifest.hostName, extensionTitle: manifest.title, commandName: command.name,
            commandMode: command.mode, assetsPath: "", supportPath: "", preferences: preferences, caches: [:],
            arguments: [:], isDarkAppearance: false)
        try await runtime.launch(session: session, owner: owner, command: command, context: context)
    }
}

// MARK: - The run

/// When a launch counts as done: a view once it shows `needle` or `items` items, a no-view
/// command once it finishes.
struct Goal {
    var needle: String?
    var items = 1
}

func environmentPreferences() -> [String: ExtensionPreferenceValue] {
    guard let raw = ProcessInfo.processInfo.environment["BENCH_PREFS"],
        let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
    else { return [:] }
    return json.compactMapValues { value in
        if let flag = value as? Bool { return .bool(flag) }
        if let text = value as? String { return .string(text) }
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
        print("usage: plugin-bench <js|scrift> <directory> <command> <iterations> [cache directory]")
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
    let subject: any Subject
    do {
        if engine == "js" {
            subject = try JavaScriptSubject(
                directory: directory, command: arguments[3], preferences: environmentPreferences())
        } else {
            let cache =
                arguments.count > 5
                ? ScriftModuleCache(directory: URL(filePath: arguments[5])) : ScriftModuleCache(directory: nil)
            subject = try ScriftSubject(
                directory: directory, command: arguments[3], cache: cache, preferences: environmentPreferences())
        }
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
            if subject.command.mode != .view { return recorder.finished }
            if recorder.renders != checkedRenders {
                checkedRenders = recorder.renders
                reachedGoal = goalReached()
            }
            return reachedGoal
        }
        func goalReached() -> Bool {
            guard let root = recorder.tree?.activeRoot else { return false }
            if let needle = goal.needle { return contains(needle, in: root) }
            return items(in: root) >= goal.items
        }
        // The palette reports an uncontrolled dropdown's opening choice once it appears.
        var seeded = false
        var polls = 0
        while !done(), ContinuousClock.now - started < timeout {
            if !seeded, let tree = recorder.tree,
                let accessory = ExtensionSearchAccessory(node: tree.activeRoot?.node("searchBarAccessory"))
            {
                seeded = true
                if accessory.controlledValue == nil, let value = accessory.initialValue(stored: nil),
                    let handler = accessory.onChange
                {
                    await runtime.dispatch(
                        session: session, handler: handler, payload: ExtensionJSON.string(from: [value]))
                }
            }
            polls += 1
            if polls % 20 == 0 { maxThreads = max(maxThreads, threadCount()) }
            try? await Task.sleep(for: .milliseconds(1))
        }
        if subject.command.mode != .view { await runtime.drainHostCalls() }
        let ended = ContinuousClock.now
        let cpuDone = cpuSeconds()
        let atContent = footprint().current
        maxThreads = max(maxThreads, threadCount())
        let reached = done() && recorder.failure == nil && launchError == nil
        if environment["BENCH_DUMP"] != nil, let root = recorder.tree?.activeRoot {
            var types: [String: Int] = [:]
            func walk(_ node: RenderNode) {
                types[node.type, default: 0] += 1
                node.children.forEach(walk)
            }
            walk(root)
            print("DUMP \(types) \(root.props.keys.sorted()) \(host.log.suffix(6))")
        }

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
            "footprint_during": atContent - before,
            "footprint_retained": after - baseline.current,
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
