import Foundation

// tinycast-plugin dump <plugin folder>
// tinycast-plugin run <plugin folder> <command> [seconds]
//
// `run` launches one command against a host that prints every call it gets, waits until it
// finishes or `seconds` pass (5 by default), and prints its last screen as an outline.
//
// Runs the folder's Manifest.swift as Tinycast does, checks that main.swift compiles with the
// permissions it declares and registers just the commands it declares, and prints the manifest as
// JSON: what a plugin index or website reads, so none of them needs Stir. Scripts/plugin-dump.sh

/// No command runs while checking, so nothing reaches the app.
@MainActor
final class NoHost: ExtensionHostAPI {
    func perform(api: String, method: String, arguments: [RenderValue]) async throws -> String {
        throw ExtensionHostError.noActiveExtension
    }
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
final class PrintingHost: ExtensionHostAPI {
    func perform(api: String, method: String, arguments: [RenderValue]) async throws -> String {
        let shown = arguments.map { $0.stringValue ?? ExtensionJSON.string(from: $0.jsonValue) }
        print("host  " + ([api + "." + method] + shown).joined(separator: " "))
        return method == "showToast" ? "1" : method == "confirmAlert" ? "true" : ""
    }
    func sessionEnded() {}
}

@MainActor
final class Outcome: ExtensionRuntimeDelegate {
    var tree: RenderTree?
    var failure: String?
    var finished = false
    func runtime(_ runtime: any ExtensionCommandRuntime, session: String, didRender tree: RenderTree) { self.tree = tree }
    func runtime(_ runtime: any ExtensionCommandRuntime, session: String, didFail message: String) { failure = message }
    func runtime(_ runtime: any ExtensionCommandRuntime, session: String, navigationDepth: Int) {}
    func runtime(_ runtime: any ExtensionCommandRuntime, session: String, didFinish: Void) { finished = true }
    func runtime(_ runtime: any ExtensionCommandRuntime, log level: String, message: String) {}
}

/// `List "Cities"` with its children indented under it; handlers and nested nodes as props.
func outline(_ node: RenderNode, depth: Int = 0) -> [String] {
    let pad = String(repeating: "  ", count: depth)
    var line = pad + node.type
    if let title = node.string("title") ?? node.string("navigationTitle") { line += " \"\(title)\"" }
    var nested: [(String, RenderNode)] = []
    var shown: [String] = []
    for (name, value) in node.props.sorted(by: { $0.key < $1.key }) where name != "title" {
        if let child = value.nodeValue { nested.append((name, child)); continue }
        if let id = value.handlerID { shown.append("\(name)=⟨\(id.split(separator: ":").first ?? "")⟩"); continue }
        shown.append("\(name)=\(value.stringValue ?? ExtensionJSON.string(from: value.jsonValue))")
    }
    if !shown.isEmpty { line += "  " + shown.joined(separator: " ") }
    var lines = [line]
    for (name, child) in nested {
        lines.append(pad + "  ." + name + ":")
        lines += outline(child, depth: depth + 2)
    }
    for child in node.children { lines += outline(child, depth: depth + 1) }
    return lines
}

@MainActor func run(_ folder: URL, command name: String, seconds: Double) async {
    let (manifest, _, kit) = read(folder)
    guard let host = manifest.extensionManifest(), let command = host.commands.first(where: { $0.name == name })
    else { fail("\(folder.lastPathComponent) declares no command “\(name)”") }
    let storage = ExtensionStorage(
        directory: FileManager.default.temporaryDirectory.appending(path: "tinycast-plugin-\(UUID())"))
    let runtime = StirPluginRuntime(
        plugin: manifest, directory: folder, storage: storage, hostAPI: PrintingHost(), appScheme: "tinycast",
        kitSources: { kit })
    let outcome = Outcome()
    runtime.setDelegate(outcome)
    let context = ExtensionLaunchContext(
        extensionName: manifest.hostName, extensionTitle: manifest.title, commandName: name,
        commandMode: command.mode, assetsPath: "", supportPath: "", preferences: [:], caches: [:],
        arguments: [:], isDarkAppearance: false)
    let owner = InstalledExtension(manifest: host, directory: folder, engine: .plugin)
    do {
        try await runtime.launch(session: "run", owner: owner, command: command, context: context)
    } catch {
        fail(error.localizedDescription)
    }
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline, !outcome.finished, outcome.failure == nil {
        try? await Task.sleep(for: .milliseconds(20))
    }
    if let failure = outcome.failure { fail(failure) }
    if let root = outcome.tree?.activeRoot { print(outline(root).joined(separator: "\n")) }
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
        _ = try StirPluginRuntime.compile(
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
