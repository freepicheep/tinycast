import Foundation

// tinycast-plugin dump <plugin folder>
// tinycast-plugin run <plugin folder> <command> [seconds]
//
// `run` launches one command against a host that prints every call it gets, waits until it
// finishes or `seconds` pass (5 by default), and prints its last frame as JSON.
//
// Runs the folder's Manifest.swift as Tinycast does, checks that main.swift compiles with the
// permissions it declares and registers just the commands it declares, and prints the manifest as
// JSON: what a plugin index or website reads, so none of them needs Scrift. Scripts/plugin-dump.sh

/// No command runs while checking, so nothing reaches the app.
@MainActor
final class NoHost: PluginHostAPI {
    func perform(_ call: PluginHostCall) async throws -> PluginHostAnswer { throw PluginHostError.noSession }
    func sessionEnded() {}
}

/// The repository this tool was built from, whose kit and description it checks against.
let repository = URL(filePath: #filePath).deletingLastPathComponent()  // tinycast-plugin
    .deletingLastPathComponent()  // Sources
    .deletingLastPathComponent()  // PluginHost
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()
let resources = repository.appending(path: "Tinycast/Resources")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Prints what a running command asks of the app.
@MainActor
final class PrintingHost: PluginHostAPI {
    func perform(_ call: PluginHostCall) async throws -> PluginHostAnswer {
        print("host  \(call)")
        switch call {
        case .showToast: return .int(1)
        case .confirm: return .bool(true)
        default: return .none
        }
    }
    func sessionEnded() {}
}

@MainActor
final class Outcome: PluginRuntimeDelegate {
    var frame: PluginFrame?
    var failure: String?
    var finished = false
    func runtime(_ runtime: any PluginRuntime, session: String, didRender frame: PluginFrame) { self.frame = frame }
    func runtime(_ runtime: any PluginRuntime, session: String, didFail message: String) { failure = message }
    func runtime(_ runtime: any PluginRuntime, session: String, didFinish: Void) { finished = true }
}

@MainActor func run(_ folder: URL, command name: String, seconds: Double) async {
    let (manifest, _, kit) = read(folder)
    guard manifest.commands.contains(where: { $0.name == name }) else {
        fail("\(folder.lastPathComponent) declares no command “\(name)”")
    }
    let runtime = ScriftPluginRuntime(
        plugin: manifest, directory: folder, storage: PluginMemoryStorage(), hostAPI: PrintingHost(),
        appScheme: "tinycast", kitSources: { kit })
    let outcome = Outcome()
    runtime.setDelegate(outcome)
    let launch = PluginLaunch(
        commandName: name, isBackground: false, arguments: [:], preferences: [:], fallbackText: nil,
        launchContext: [:], isDarkAppearance: false)
    do {
        try await runtime.launch(session: "run", launch: launch)
    } catch {
        fail(error.localizedDescription)
    }
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline, !outcome.finished, outcome.failure == nil {
        try? await Task.sleep(for: .milliseconds(20))
    }
    if let failure = outcome.failure { fail(failure) }
    if let frame = outcome.frame {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: (try? encoder.encode(frame)) ?? Data(), as: UTF8.self))
    }
    if outcome.finished { print("finished") }
    await runtime.stop(session: "run")
}

/// The folder's manifest and sources, and the kit, or the reason they can't be read.
@MainActor func read(_ folder: URL) -> (PluginManifest, PluginSources, PluginSources) {
    let name = folder.lastPathComponent
    guard let source = try? String(contentsOf: folder.appending(path: PluginManifestReader.fileName), encoding: .utf8)
    else { fail("\(name): no readable Manifest.swift") }
    let description: PluginSources
    let kit: PluginSources
    do {
        description = try PluginSources.read(
            from: resources.appending(path: PluginManifestReader.descriptionModule), requiringMain: false)
        kit = try PluginSources.read(from: resources.appending(path: "PluginKit"), requiringMain: false)
    } catch {
        fail("can't read Tinycast's plugin resources: \(error.description)")
    }
    let manifest: PluginManifest
    switch PluginManifestReader.evaluate(source, description: description) {
    case .success(let value): manifest = value
    case .failure(let error): fail("\(name): \(error.description)")
    }
    let sources: PluginSources
    do {
        sources = try PluginSources.read(from: folder)
    } catch {
        fail("\(name): \(error.description)")
    }
    return (manifest, sources, kit)
}

@MainActor func dump(_ folder: URL) -> Data {
    let name = folder.lastPathComponent
    let (manifest, sources, kit) = read(folder)
    do {
        _ = try ScriftPluginRuntime.compile(
            plugin: manifest, kit: kit, sources: sources, hostAPI: NoHost(), output: { _ in })
    } catch {
        fail("\(name): \(error.description)")
    }
    return manifest.json()
}

setvbuf(stdout, nil, _IONBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())
func folder(_ path: String) -> URL { URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL }
switch (arguments.first, arguments.count) {
case ("dump", 2):
    var output = dump(folder(arguments[1]))
    output.append(contentsOf: Data("\n".utf8))
    FileHandle.standardOutput.write(output)
case ("run", 3), ("run", 4):
    await run(folder(arguments[1]), command: arguments[2], seconds: arguments.count == 4 ? Double(arguments[3]) ?? 5 : 5)
default:
    fail("usage: tinycast-plugin dump <plugin folder>\n       tinycast-plugin run <plugin folder> <command> [seconds]")
}
