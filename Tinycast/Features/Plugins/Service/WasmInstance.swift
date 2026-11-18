import Foundation
import JavaScriptCore
import Security

/// One metered plugin module, instantiated in a `JSContext` of its own. Not thread-safe: its owner
/// makes every call on one queue, and the imports call back on it, inside the export that ran them.
///
/// The module sees WASI with no files, no environment and no clock it can sleep on — its standard
/// output and error are kept for the error report — and the `tinycast` imports below.
final class WasmInstance {
    /// The `tinycast` imports, as the owner answers them. Strings arrive decoded from the
    /// module's memory.
    struct Imports {
        var render: (UInt32, String) -> Void = { _, _ in }
        var navigation: (UInt32, UInt32) -> Void = { _, _ in }
        var finished: (UInt32) -> Void = { _ in }
        var failed: (UInt32, String) -> Void = { _, _ in }
        var call: (UInt32, String) -> Void = { _, _ in }
        var setTimer: (UInt32, Double) -> Void = { _, _ in }
        var clearTimer: (UInt32) -> Void = { _ in }
        var manifest: (String) -> Void = { _ in }
        var output: (String) -> Void = { _ in }
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case compile(String)
        case missingImport(String)
        case deadline(Duration)
        case exited(Int)
        case trap(String)

        var description: String {
            switch self {
            case .compile(let reason): "plugin.wasm can't be compiled: \(reason)"
            case .missingImport(let name): "plugin.wasm imports \(name), which Tinycast doesn't provide"
            case .deadline(let budget):
                "The plugin ran for more than \(budget.components.seconds) seconds without returning, so Tinycast stopped it."
            case .exited(let code): "The plugin exited with code \(code)."
            case .trap(let reason): "The plugin crashed: \(reason)"
            }
        }
    }

    /// How long one call into the plugin may run before the refuel hook stops it.
    let budget: Duration
    private let context: JSContext
    private let glue: JSValue
    private var deadline: ContinuousClock.Instant?
    private var thrown: JSValue?

    /// `module` is metered by `WasmMeter`; compiling, linking and `_initialize` happen here.
    init(module: Data, imports: Imports, budget: Duration = .seconds(5)) throws(Failure) {
        self.budget = budget
        guard let context = JSContext() else { throw .compile("JavaScriptCore has no context to give") }
        self.context = context
        var thrown: JSValue?
        context.exceptionHandler = { _, exception in thrown = exception }
        let instantiate = context.evaluateScript(Self.glueSource)
        let host = Self.host(in: context, imports: imports)
        guard let bytes = Self.typedArray(module, in: context) else { throw .compile("out of memory") }
        let glue = instantiate?.call(withArguments: [bytes, host])
        if let thrown { throw Self.failure(thrown, budget: budget) }
        guard let glue, glue.isObject else { throw .compile("the module didn't instantiate") }
        self.glue = glue
        context.exceptionHandler = { [weak self] _, exception in self?.thrown = exception }
        // The refuel hook asks this instance, so it can be set only once `self` exists.
        let overdue: @convention(block) () -> Bool = { [weak self] in
            guard let self, let deadline = self.deadline else { return false }
            return ContinuousClock.now > deadline
        }
        host.setObject(overdue, forKeyedSubscript: "overdue" as NSString)
        try call("_initialize")
    }

    /// Calls an export with numbers; a string argument is written into the module's memory first.
    @discardableResult
    func call(_ export: String, _ arguments: [Argument] = []) throws(Failure) -> JSValue? {
        var values: [Any] = []
        for argument in arguments {
            switch argument {
            case .number(let number): values.append(number)
            case .text(let text):
                let (pointer, length) = try put(text)
                values += [pointer, length]
            }
        }
        thrown = nil
        deadline = ContinuousClock.now + budget
        defer { deadline = nil }
        let result = glue.invokeMethod("call", withArguments: [export] + values)
        if let thrown {
            self.thrown = nil
            throw Self.failure(thrown, budget: budget)
        }
        return result
    }

    enum Argument {
        case number(Double)
        /// Becomes two arguments, the bytes' address and length, in memory the kit frees.
        case text(String)

        static func number(_ value: UInt32) -> Argument { .number(Double(value)) }
    }

    private func put(_ text: String) throws(Failure) -> (Int, Int) {
        let data = Data(text.utf8)
        guard let bytes = Self.typedArray(data, in: context) else { throw .trap("out of memory") }
        thrown = nil
        let pointer = glue.invokeMethod("put", withArguments: [bytes])?.toInt32() ?? 0
        if let thrown {
            self.thrown = nil
            throw Self.failure(thrown, budget: budget)
        }
        return (Int(pointer), data.count)
    }

    // MARK: - The host object the glue calls

    private static func host(in context: JSContext, imports: Imports) -> JSValue {
        let host = JSValue(newObjectIn: context)!
        func set(_ name: String, _ block: Any) {
            host.setObject(block, forKeyedSubscript: name as NSString)
        }
        let render: @convention(block) (UInt32, JSValue) -> Void = { imports.render($0, text($1)) }
        let navigation: @convention(block) (UInt32, UInt32) -> Void = { imports.navigation($0, $1) }
        let finished: @convention(block) (UInt32) -> Void = { imports.finished($0) }
        let failed: @convention(block) (UInt32, JSValue) -> Void = { imports.failed($0, text($1)) }
        let call: @convention(block) (UInt32, JSValue) -> Void = { imports.call($0, text($1)) }
        let setTimer: @convention(block) (UInt32, Double) -> Void = { imports.setTimer($0, $1) }
        let clearTimer: @convention(block) (UInt32) -> Void = { imports.clearTimer($0) }
        let manifest: @convention(block) (JSValue) -> Void = { imports.manifest(text($0)) }
        let output: @convention(block) (JSValue) -> Void = { imports.output(text($0)) }
        let random: @convention(block) (Int) -> JSValue? = { count in
            var bytes = Data(count: max(count, 0))
            let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
            precondition(status == errSecSuccess, "the system's random generator failed")
            return JSContext.current().flatMap { typedArray(bytes, in: $0) }
        }
        let start = ContinuousClock.now
        let monotonic: @convention(block) () -> Double = {
            let elapsed = ContinuousClock.now - start
            return Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
        }
        set("render", render)
        set("navigation", navigation)
        set("finished", finished)
        set("failed", failed)
        set("call", call)
        set("setTimer", setTimer)
        set("clearTimer", clearTimer)
        set("manifest", manifest)
        set("output", output)
        set("random", random)
        set("monotonic", monotonic)
        return host
    }

    /// A `Uint8Array` view of the module's memory, decoded as UTF-8.
    private static func text(_ value: JSValue) -> String {
        guard let context = value.context?.jsGlobalContextRef,
            let base = JSObjectGetTypedArrayBytesPtr(context, value.jsValueRef, nil)
        else { return "" }
        // The pointer is the whole buffer's; a view into memory starts at its offset.
        let offset = JSObjectGetTypedArrayByteOffset(context, value.jsValueRef, nil)
        let length = JSObjectGetTypedArrayByteLength(context, value.jsValueRef, nil)
        return String(decoding: UnsafeRawBufferPointer(start: base + offset, count: length), as: UTF8.self)
    }

    private static func typedArray(_ data: Data, in context: JSContext) -> JSValue? {
        let ref = context.jsGlobalContextRef
        guard let array = JSObjectMakeTypedArray(ref, kJSTypedArrayTypeUint8Array, data.count, nil),
            let pointer = JSObjectGetTypedArrayBytesPtr(ref, array, nil)
        else { return nil }
        data.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
        return JSValue(jsValueRef: array, in: context)
    }

    private static func failure(_ exception: JSValue, budget: Duration) -> Failure {
        let message = exception.objectForKeyedSubscript("message")?.toString() ?? exception.toString() ?? ""
        if message == "tinycast:deadline" { return .deadline(budget) }
        if message.hasPrefix("tinycast:exit:") { return .exited(Int(message.dropFirst(14)) ?? 1) }
        if message.hasPrefix("tinycast:import:") { return .missingImport(String(message.dropFirst(16))) }
        let name = exception.objectForKeyedSubscript("name")?.toString() ?? ""
        if name == "CompileError" || name == "LinkError" { return .compile(message) }
        return .trap(message)
    }

    // MARK: - The glue

    /// The WASI the module gets and the `tinycast` imports, in JavaScript because JavaScriptCore's
    /// WebAssembly is reached only from there. The refuel hook is a one-function module that
    /// imports a JavaScript function, so it can sit in the metered module's table.
    private static let glueSource = """
        (function (bytes, host) {
          "use strict";
          const module = new WebAssembly.Module(bytes);
          let instance = null;
          const buffer = () => instance.exports.memory.buffer;
          const bytesAt = (pointer, length) => new Uint8Array(buffer(), pointer, length);
          const view = () => new DataView(buffer());
          const EBADF = 8, ENOSYS = 52, ENOTCAPABLE = 76;
          const zeroCounts = (count, size) => { const v = view(); v.setUint32(count, 0, true); v.setUint32(size, 0, true); return 0; };
          const wasi = {
            args_sizes_get: zeroCounts, args_get: () => 0,
            environ_sizes_get: zeroCounts, environ_get: () => 0,
            fd_write(fd, iovs, count, written) {
              if (fd !== 1 && fd !== 2) return EBADF;
              const v = view();
              let total = 0;
              for (let i = 0; i < count; i++) {
                const pointer = v.getUint32(iovs + 8 * i, true), length = v.getUint32(iovs + 8 * i + 4, true);
                if (length > 0) host.output(bytesAt(pointer, length));
                total += length;
              }
              view().setUint32(written, total, true);
              return 0;
            },
            fd_read(fd, iovs, count, read) { if (fd !== 0) return EBADF; view().setUint32(read, 0, true); return 0; },
            fd_fdstat_get(fd, out) {
              if (fd > 2) return EBADF;
              const v = view();
              v.setUint8(out, 2); v.setUint16(out + 2, 0, true);
              v.setBigUint64(out + 8, 0n, true); v.setBigUint64(out + 16, 0n, true);
              return 0;
            },
            fd_close: () => EBADF, fd_seek: () => EBADF, fd_prestat_get: () => EBADF,
            fd_prestat_dir_name: () => EBADF, path_open: () => ENOTCAPABLE,
            random_get(pointer, length) { bytesAt(pointer, length).set(host.random(length)); return 0; },
            clock_time_get(id, precision, out) {
              const now = id === 0 ? BigInt(Date.now()) * 1000000n : BigInt(Math.round(host.monotonic()));
              view().setBigUint64(out, now, true);
              return 0;
            },
            clock_res_get(id, out) { view().setBigUint64(out, 1000n, true); return 0; },
            sched_yield: () => 0,
            proc_exit(code) { throw new Error("tinycast:exit:" + code); },
          };
          const tinycast = {
            render: (session, pointer, length) => host.render(session, bytesAt(pointer, length)),
            navigation: (session, depth) => host.navigation(session, depth),
            finished: (session) => host.finished(session),
            failed: (session, pointer, length) => host.failed(session, bytesAt(pointer, length)),
            call: (id, pointer, length) => host.call(id, bytesAt(pointer, length)),
            set_timer: (token, milliseconds) => host.setTimer(token, milliseconds),
            clear_timer: (token) => host.clearTimer(token),
            manifest: (pointer, length) => host.manifest(bytesAt(pointer, length)),
          };
          const imports = { wasi_snapshot_preview1: {}, tinycast: {} };
          for (const entry of WebAssembly.Module.imports(module)) {
            if (entry.module === "wasi_snapshot_preview1") {
              imports.wasi_snapshot_preview1[entry.name] = wasi[entry.name] || (() => ENOSYS);
            } else if (entry.module === "tinycast" && tinycast[entry.name]) {
              imports.tinycast[entry.name] = tinycast[entry.name];
            } else {
              throw new Error("tinycast:import:" + entry.module + "." + entry.name);
            }
          }
          instance = new WebAssembly.Instance(module, imports);
          const refuel = new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array([
            0, 0x61, 0x73, 0x6d, 1, 0, 0, 0, 1, 5, 1, 0x60, 0, 1, 0x7e, 2, 7, 1, 1, 0x68, 1, 0x72, 0, 0,
            7, 5, 1, 1, 0x72, 0, 0])), { h: { r: () => { if (host.overdue()) throw new Error("tinycast:deadline"); return 100000n; } } });
          instance.exports.tinycast_refuel.set(0, refuel.exports.r);
          instance.exports.tinycast_fuel.value = 100000n;
          return {
            call: (name, ...args) => instance.exports[name](...args),
            put(data) {
              const pointer = instance.exports.tinycast_alloc(data.length);
              new Uint8Array(buffer(), pointer, data.length).set(data);
              return pointer;
            },
          };
        })
        """
}
