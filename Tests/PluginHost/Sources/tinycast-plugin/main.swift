import Foundation

// tinycast-plugin dump <plugin folder>
//
// Runs the folder's Manifest.swift as Tinycast does, checks that main.swift compiles with the
// permissions it declares and registers just the commands it declares, and prints the manifest as
// JSON: what a plugin index or website reads, so none of them needs Stir. Scripts/plugin-dump.sh

@MainActor
final class NoServices: PluginHostServices {
    func showHUD(_ text: String) {}
    func closeWindow() {}
    func copy(_ text: String) {}
    func paste(_ text: String) {}
    func open(_ url: URL) {}
    func refuseOpen(_ target: String) {}
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

@MainActor func dump(_ folder: URL) -> Data {
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
    // A session compiles and runs main.swift and checks its registrations; no command starts.
    let storage = FileManager.default.temporaryDirectory.appending(path: "tinycast-plugin-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: storage) }
    do {
        let session = try PluginSession(
            manifest: manifest, command: manifest.commands[0], sources: sources, kit: kit,
            storage: PluginStorage(fileURL: storage), services: NoServices())
        session.close()
    } catch {
        fail("\(name): \(error.description)")
    }
    return manifest.json()
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, arguments[0] == "dump" else {
    fail("usage: tinycast-plugin dump <plugin folder>")
}
var output = dump(URL(filePath: arguments[1], directoryHint: .isDirectory).standardizedFileURL)
output.append(contentsOf: Data("\n".utf8))
FileHandle.standardOutput.write(output)
