import Foundation
import JavaScriptCore

@main
@MainActor
struct PluginTests {
    static var failures = 0

    static func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: String = "") {
        if condition() {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)" + (detail.isEmpty ? "" : "\n      \(detail)"))
        }
    }

    static func main() {
        meterChecks()
        meteredRunChecks()
        policyChecks()
        manifestChecks()
        if failures > 0 {
            print("\(failures) plugin checks failed.")
            exit(1)
        }
    }

    // MARK: - Modules by hand

    static func section(_ id: UInt8, _ body: [UInt8]) -> [UInt8] { [id] + WasmMeter.leb(UInt64(body.count)) + body }
    static func name(_ text: String) -> [UInt8] { [UInt8(text.utf8.count)] + Array(text.utf8) }

    /// `spin` loops forever; `add` adds; memory starts at `pages`, with `maximum` if given.
    static func module(pages: UInt8 = 1, maximum: UInt8? = nil, extraExport: String? = nil, body: [UInt8]? = nil) -> [UInt8] {
        let header: [UInt8] = [0, 0x61, 0x73, 0x6D, 1, 0, 0, 0]
        let types = section(1, [2, 0x60, 0, 0, 0x60, 2, 0x7F, 0x7F, 1, 0x7F])
        let functions = section(3, [2, 0, 1])
        let memory = section(5, [1] + (maximum.map { [1, pages, $0] } ?? [0, pages]))
        var exports: [[UInt8]] = [name("memory") + [2, 0], name("spin") + [0, 0], name("add") + [0, 1]]
        if let extraExport { exports.append(name(extraExport) + [3, 0]) }
        let exportSection = section(7, [UInt8(exports.count)] + exports.flatMap { $0 })
        let spin: [UInt8] = body ?? [0, 0x03, 0x40, 0x0C, 0x00, 0x0B, 0x0B]
        let add: [UInt8] = [0, 0x20, 0, 0x20, 1, 0x6A, 0x0B]
        let code = section(10, [2, UInt8(spin.count)] + spin + [UInt8(add.count)] + add)
        let global = extraExport == nil ? [] : section(6, [1, 0x7F, 0, 0x41, 0, 0x0B])
        return header + types + functions + memory + global + exportSection + code
    }

    static func meterChecks() {
        let plain = module()
        guard let metered = try? WasmMeter.instrument(plain, memoryCap: 16) else {
            return check("a plain module meters", false)
        }
        check("a plain module meters", true)
        let context = JSContext()!
        let validate = context.evaluateScript("(b) => WebAssembly.validate(new Uint8Array(b))")!
        check("the metered module is valid WebAssembly", validate.call(withArguments: [metered])?.toBool() == true)
        let exports = context.evaluateScript(
            "(b) => WebAssembly.Module.exports(new WebAssembly.Module(new Uint8Array(b)))"
                + ".map(e => e.name + ':' + e.kind).join(',')")!
            .call(withArguments: [metered])?.toString() ?? ""
        check(
            "it exports the fuel global and the refuel table",
            exports.contains("tinycast_fuel:global") && exports.contains("tinycast_refuel:table"), exports)
        check(
            "a module with a global of its own meters too",
            (try? WasmMeter.instrument(module(extraExport: "counter"), memoryCap: 16))
                .map { validate.call(withArguments: [$0])?.toBool() == true } ?? false)
        check(
            "metering twice is refused",
            (try? WasmMeter.instrument(metered, memoryCap: 16)) == nil)
        do {
            _ = try WasmMeter.instrument(module(pages: 32), memoryCap: 16)
            check("a module starting above the cap is refused", false)
        } catch {
            check("a module starting above the cap is refused", error == .memoryTooLarge(pages: 32, cap: 16))
        }
        do {
            _ = try WasmMeter.instrument(module(body: [0, 0xFB, 0x00, 0x0B]), memoryCap: 16)
            check("an instruction the meter can't read is refused", false)
        } catch {
            check("an instruction the meter can't read is refused", error == .unsupportedOpcode(0xFB, nil))
        }
        check("a file that isn't WebAssembly is refused", (try? WasmMeter.instrument(Array("hello".utf8), memoryCap: 16)) == nil)
        let maxed = (try? WasmMeter.instrument(module(maximum: 100), memoryCap: 16)) ?? []
        let maximum = context.evaluateScript("""
            (b) => { const i = new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array(b)), {});
              try { i.exports.memory.grow(100); return 'grew'; } catch (e) { return 'capped'; } }
            """)!.call(withArguments: [maxed])?.toString()
        check("memory can't grow past the cap, whatever the module declared", maximum == "capped", maximum ?? "")
    }

    /// The refuel hook stops a loop that never returns, and leaves a call that returns alone.
    static func meteredRunChecks() {
        guard let metered = try? WasmMeter.instrument(module(), memoryCap: 16) else { return }
        let context = JSContext()!
        let result = context.evaluateScript("""
            (b) => {
              let refills = 0;
              const i = new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array(b)), {});
              const hook = new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array([
                0, 0x61, 0x73, 0x6d, 1, 0, 0, 0, 1, 5, 1, 0x60, 0, 1, 0x7e, 2, 7, 1, 1, 0x68, 1, 0x72, 0, 0,
                7, 5, 1, 1, 0x72, 0, 0])),
                { h: { r: () => { refills++; if (refills > 3) throw new Error('stop'); return 1000n; } } });
              i.exports.tinycast_refuel.set(0, hook.exports.r);
              i.exports.tinycast_fuel.value = 1000n;
              const sum = i.exports.add(2, 3);
              try { i.exports.spin(); return 'returned'; } catch (e) { return sum + ' ' + e.message + ' ' + refills; }
            }
            """)!.call(withArguments: [metered])?.toString()
        check("a metered call that returns is unchanged", result?.hasPrefix("5 ") == true, result ?? "")
        check("a metered loop asks for fuel until the hook stops it", result == "5 stop 4", result ?? "")
    }

    // MARK: - What a plugin's calls may reach

    static func manifest(_ permissions: Set<PluginPermission> = [], schemes: Set<String> = []) -> PluginManifest {
        PluginManifest(
            name: "sample", title: "Sample", description: nil, icon: nil, author: nil, permissions: permissions,
            urlSchemes: schemes, preferences: [], commands: [])
    }

    static func allowed(
        _ api: String, _ method: String, _ arguments: [RenderValue] = [], _ manifest: PluginManifest = manifest()
    ) -> Bool {
        PluginHostPolicy.refusal(api: api, method: method, arguments: arguments, manifest: manifest) == nil
    }

    static func policyChecks() {
        check("storage, toasts and windows need no permission",
            allowed("storage", "set") && allowed("feedback", "showToast") && allowed("window", "close")
                && allowed("cache", "set") && allowed("form", "store") && allowed("oauth", "authorize"))
        check("copying needs no permission; reading the clipboard does",
            allowed("clipboard", "copy") && !allowed("clipboard", "readText")
                && allowed("clipboard", "readText", [], manifest([.clipboard])))
        check("fetch needs the network permission",
            !allowed("fetch", "request") && allowed("fetch", "request", [], manifest([.network])))
        check("WebSockets and name lookups are the network too",
            !allowed("websocket", "open") && !allowed("dns", "resolve")
                && allowed("websocket", "open", [], manifest([.network])))
        check("a Unix socket is refused even with the network",
            !allowed("fetch", "request", [.object(["socketPath": .string("/var/run/docker.sock")])], manifest([.network])))
        check("the selection needs its permission",
            !allowed("system", "selectedText") && allowed("system", "selectedFinderItems", [], manifest([.selection])))
        check("web links and paths open; an app scheme only when declared",
            allowed("system", "open", [.string("https://example.com")])
                && allowed("system", "open", [.string("/Applications")])
                && !allowed("system", "open", [.string("cleanshot://capture")])
                && allowed("system", "open", [.string("cleanshot://capture")], manifest(schemes: ["cleanshot"])))
        check("Tinycast's own links never open, even when declared",
            !allowed("system", "open", [.string("tinycast://extensions/x/y")], manifest(schemes: ["tinycast"])))
        check("a plugin launches its own commands only",
            allowed("system", "launchCommand", [.object(["name": .string("a")])])
                && allowed("system", "launchCommand", [.object(["extensionName": .string("plugin.sample")])])
                && !allowed("system", "launchCommand", [.object(["extensionName": .string("plugin.other")])]))
        check("processes and unknown APIs don't exist for plugins",
            !allowed("proc", "wait") && !allowed("system", "runAppleScript") && !allowed("nope", "x"))
    }

    // MARK: - Manifests

    static func decode(_ json: String) -> Result<PluginManifest, PluginManifestError> {
        Result { () throws(PluginManifestError) in try PluginManifest.decode(Data(json.utf8)) }
    }

    static func manifestChecks() {
        let good = decode("""
            {"name":"world-clock","title":"World Clock","permissions":["network"],
             "commands":[{"name":"clocks","title":"Clocks","mode":"view"},
                         {"name":"refresh","title":"Refresh","mode":"no-view","interval":"10m"}]}
            """)
        check("a manifest decodes", (try? good.get())?.commands.map(\.mode) == [.view, .action])
        check("its host name keeps it apart from Raycast's", (try? good.get())?.hostName == "plugin.world-clock")
        check("an unknown permission is refused",
            decode(#"{"name":"a","title":"A","permissions":["files"],"commands":[{"name":"x","title":"X"}]}"#)
                == .failure(.unknownPermission("files")))
        check("a name with capitals is refused",
            decode(#"{"name":"World","title":"A","commands":[{"name":"x","title":"X"}]}"#) == .failure(.invalidName("World")))
        check("no commands is refused", decode(#"{"name":"a","title":"A","commands":[]}"#) == .failure(.noCommands))
        check("a bad interval is refused",
            decode(#"{"name":"a","title":"A","commands":[{"name":"x","title":"X","interval":"often"}]}"#)
                == .failure(.invalidInterval("often")))
        check("Tinycast's scheme can't be claimed",
            decode(#"{"name":"a","title":"A","urlSchemes":["tinycast"],"commands":[{"name":"x","title":"X"}]}"#)
                == .failure(.invalidURLScheme("tinycast")))
    }
}
