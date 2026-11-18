import Foundation

/// Rewrites a plugin's WebAssembly before it is compiled, so the host can bound it. Every function
/// entry and loop header spends one unit of an exported `tinycast_fuel` global; when it runs out,
/// the module calls the function the host put in the exported `tinycast_refuel` table, which hands
/// back another slice or throws once the call into the plugin has run past its deadline. The
/// module's own memory gets a maximum.
///
/// Every index added comes after the module's own — a type, a table, a global, two exports — so no
/// call, element or data segment needs renumbering.
enum WasmMeter {
    static let fuelExport = "tinycast_fuel"
    static let refuelExport = "tinycast_refuel"

    enum Failure: Error, Equatable, CustomStringConvertible {
        case notWasm
        case truncated
        case importedMemory
        case noMemory
        case memoryTooLarge(pages: UInt64, cap: UInt64)
        case unsupportedMemory
        case unsupportedOpcode(UInt8, UInt32?)
        case alreadyMetered

        var description: String {
            switch self {
            case .notWasm: "isn't a WebAssembly module"
            case .truncated: "ends in the middle of a section"
            case .importedMemory: "imports its memory; a plugin defines its own"
            case .noMemory: "has no memory"
            case .memoryTooLarge(let pages, let cap):
                "starts with \(pages * 64) KiB of memory, more than the \(cap * 64) KiB a plugin may use"
            case .unsupportedMemory: "uses shared or 64-bit memory, which plugins can't"
            case .unsupportedOpcode(let opcode, let sub):
                "uses an instruction Tinycast doesn't run (0x\(String(opcode, radix: 16))"
                    + (sub.map { " \($0)" } ?? "") + ")"
            case .alreadyMetered: "already exports \(WasmMeter.fuelExport)"
            }
        }
    }

    /// `memoryCap` in 64 KiB pages.
    static func instrument(_ module: [UInt8], memoryCap: UInt64) throws(Failure) -> [UInt8] {
        guard module.count >= 8, module[0..<8].elementsEqual([0, 0x61, 0x73, 0x6D, 1, 0, 0, 0]) else {
            throw .notWasm
        }
        var sections: [(id: UInt8, body: [UInt8])] = []
        var reader = Reader(bytes: module, position: 8)
        while !reader.atEnd {
            let id = try reader.byte()
            let size = Int(try reader.u32())
            sections.append((id, try reader.bytes(size)))
        }

        var counts = Counts()
        var hasMemory = false
        for section in sections {
            var reader = Reader(bytes: section.body)
            switch section.id {
            case 1: counts.types = try reader.u32()
            case 2:
                let imports = try importCounts(section.body)
                if imports.memories > 0 { throw .importedMemory }
                counts.importedGlobals = imports.globals
                counts.importedTables = imports.tables
            case 4: counts.tables = try reader.u32()
            case 5: hasMemory = true
            case 6: counts.globals = try reader.u32()
            case 7:
                let names = try exportNames(section.body)
                if names.contains(fuelExport) || names.contains(refuelExport) { throw .alreadyMetered }
            default: break
            }
        }
        guard hasMemory else { throw .noMemory }
        let fuel = counts.importedGlobals + counts.globals
        let table = counts.importedTables + counts.tables

        let additions: [UInt8: [UInt8]] = [
            // () -> i64: the refuel function's type.
            1: [0x60, 0x00, 0x01, 0x7E],
            // funcref, exactly one slot.
            4: [0x70, 0x01, 0x01, 0x01],
            // i64, mutable, `i64.const 0`: the host fills it before the first call.
            6: [0x7E, 0x01, 0x42, 0x00, 0x0B],
            7: name(fuelExport) + [0x03] + leb(UInt64(fuel)) + name(refuelExport) + [0x01]
                + leb(UInt64(table))
        ]
        let entryCounts: [UInt8: UInt64] = [1: 1, 4: 1, 6: 1, 7: 2]
        var placed: Set<UInt8> = []
        var output: [UInt8] = Array(module[0..<8])

        func emit(_ id: UInt8, _ body: [UInt8]) {
            output.append(id)
            output += leb(UInt64(body.count))
            output += body
        }
        func emitMissing(before rank: Int) {
            for id in additions.keys.sorted(by: { order($0) < order($1) })
            where !placed.contains(id) && order(id) < rank {
                emit(id, leb(entryCounts[id]!) + additions[id]!)
                placed.insert(id)
            }
        }

        for section in sections {
            if section.id != 0 { emitMissing(before: order(section.id)) }
            if let addition = additions[section.id] {
                emit(section.id, try appending(addition, count: entryCounts[section.id]!, to: section.body))
                placed.insert(section.id)
                continue
            }
            switch section.id {
            case 5: emit(5, try capMemory(section.body, cap: memoryCap))
            case 10:
                emit(10, try meterCode(section.body, fuel: fuel, refuelType: counts.types, table: table))
            default: emit(section.id, section.body)
            }
        }
        emitMissing(before: .max)
        return output
    }

    private struct Counts {
        var types: UInt32 = 0
        var importedGlobals: UInt32 = 0
        var importedTables: UInt32 = 0
        var tables: UInt32 = 0
        var globals: UInt32 = 0
    }

    // MARK: - Sections

    /// Section ids in the order a module must hold them: a tag sits between memory and global,
    /// and the data count before code.
    private static func order(_ id: UInt8) -> Int {
        [1, 2, 3, 4, 5, 13, 6, 7, 8, 9, 12, 10, 11].firstIndex(of: id) ?? Int(id) + 20
    }

    private static func appending(
        _ entries: [UInt8], count added: UInt64, to vector: [UInt8]
    ) throws(Failure) -> [UInt8] {
        var reader = Reader(bytes: vector)
        let count = try reader.u32()
        return leb(UInt64(count) + added) + Array(vector[reader.position...]) + entries
    }

    private static func importCounts(
        _ body: [UInt8]
    ) throws(Failure) -> (globals: UInt32, tables: UInt32, memories: UInt32) {
        var reader = Reader(bytes: body)
        var globals: UInt32 = 0
        var tables: UInt32 = 0
        var memories: UInt32 = 0
        for _ in 0..<(try reader.u32()) {
            try reader.skipName()
            try reader.skipName()
            switch try reader.byte() {
            case 0: _ = try reader.u32()
            case 1:
                tables += 1
                _ = try reader.byte()
                try reader.skipLimits()
            case 2:
                memories += 1
                try reader.skipLimits()
            case 3:
                globals += 1
                _ = try reader.byte()
                _ = try reader.byte()
            case 4:
                _ = try reader.byte()
                _ = try reader.u32()
            default: throw .truncated
            }
        }
        return (globals, tables, memories)
    }

    private static func exportNames(_ body: [UInt8]) throws(Failure) -> [String] {
        var reader = Reader(bytes: body)
        var names: [String] = []
        for _ in 0..<(try reader.u32()) {
            let length = Int(try reader.u32())
            names.append(String(bytes: try reader.bytes(length), encoding: .utf8) ?? "")
            _ = try reader.byte()
            _ = try reader.u32()
        }
        return names
    }

    private static func capMemory(_ body: [UInt8], cap: UInt64) throws(Failure) -> [UInt8] {
        var reader = Reader(bytes: body)
        let count = try reader.u32()
        var output = leb(UInt64(count))
        for _ in 0..<count {
            let flags = try reader.byte()
            guard flags <= 1 else { throw .unsupportedMemory }
            let minimum = try reader.u64()
            let maximum = flags == 1 ? try reader.u64() : cap
            guard minimum <= cap else { throw .memoryTooLarge(pages: minimum, cap: cap) }
            output += [1] + leb(minimum) + leb(min(maximum, cap))
        }
        return output
    }

    private static func meterCode(
        _ body: [UInt8], fuel: UInt32, refuelType: UInt32, table: UInt32
    ) throws(Failure) -> [UInt8] {
        let index = leb(UInt64(fuel))
        // fuel -= 1; if fuel < 0 { fuel = refuel() }
        let charge: [UInt8] =
            [0x23] + index + [0x42, 0x01, 0x7D, 0x24] + index
            + [0x23] + index + [0x42, 0x00, 0x53, 0x04, 0x40]
            + [0x41, 0x00, 0x11] + leb(UInt64(refuelType)) + leb(UInt64(table)) + [0x24] + index + [0x0B]
        var reader = Reader(bytes: body)
        let count = try reader.u32()
        var output = leb(UInt64(count))
        for _ in 0..<count {
            let size = Int(try reader.u32())
            let function = try reader.bytes(size)
            var metered: [UInt8] = []
            metered.reserveCapacity(function.count + charge.count * 4)
            var code = Reader(bytes: function)
            for _ in 0..<(try code.u32()) {
                _ = try code.u32()
                _ = try code.byte()
            }
            metered += function[0..<code.position]
            metered += charge
            var start = code.position
            while !code.atEnd {
                let isLoop = try code.instruction()
                if isLoop {
                    metered += function[start..<code.position]
                    metered += charge
                    start = code.position
                }
            }
            metered += function[start...]
            output += leb(UInt64(metered.count)) + metered
        }
        return output
    }

    // MARK: - Encoding

    private static func name(_ text: String) -> [UInt8] {
        leb(UInt64(text.utf8.count)) + Array(text.utf8)
    }

    static func leb(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    private struct Reader {
        let bytes: [UInt8]
        var position = 0

        init(bytes: [UInt8], position: Int = 0) {
            self.bytes = bytes
            self.position = position
        }

        var atEnd: Bool { position >= bytes.count }

        mutating func byte() throws(Failure) -> UInt8 {
            guard position < bytes.count else { throw .truncated }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func bytes(_ count: Int) throws(Failure) -> [UInt8] {
            guard count >= 0, position + count <= bytes.count else { throw .truncated }
            defer { position += count }
            return Array(bytes[position..<position + count])
        }

        mutating func skip(_ count: Int) throws(Failure) {
            guard position + count <= bytes.count else { throw .truncated }
            position += count
        }

        mutating func u64() throws(Failure) -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                let byte = try byte()
                guard shift < 64 else { throw .truncated }
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }

        mutating func u32() throws(Failure) -> UInt32 { UInt32(truncatingIfNeeded: try u64()) }

        /// A signed LEB's bytes, whatever its width; only its length matters here.
        mutating func skipSigned() throws(Failure) {
            while try byte() & 0x80 != 0 {}
        }

        mutating func skipName() throws(Failure) { try skip(Int(try u32())) }

        mutating func skipLimits() throws(Failure) {
            let flags = try byte()
            _ = try u64()
            if flags & 1 != 0 { _ = try u64() }
        }

        mutating func memarg() throws(Failure) {
            let align = try u32()
            if align & 0x40 != 0 { _ = try u32() }
            _ = try u64()
        }

        /// Steps over one instruction and its immediates; true when it was a `loop`.
        mutating func instruction() throws(Failure) -> Bool {
            let opcode = try byte()
            switch opcode {
            case 0x03:
                try skipSigned()
                return true
            case 0x02, 0x04, 0x06:
                try skipSigned()
            case 0x00, 0x01, 0x05, 0x0A, 0x0B, 0x0F, 0x19, 0x1A, 0x1B, 0x45...0xC4, 0xD1, 0xD3, 0xD5:
                break
            case 0x07, 0x08, 0x09, 0x0C, 0x0D, 0x10, 0x12, 0x18, 0x20...0x26, 0x3F, 0x40, 0xD2, 0xD4, 0xD6:
                _ = try u32()
            case 0x11, 0x13:
                _ = try u32()
                _ = try u32()
            case 0x0E:
                for _ in 0...(try u32()) { _ = try u32() }
            case 0x1C:
                for _ in 0..<(try u32()) { _ = try byte() }
            case 0x1F:
                try skipSigned()
                for _ in 0..<(try u32()) {
                    let kind = try byte()
                    if kind < 2 { _ = try u32() }
                    _ = try u32()
                }
            case 0x28...0x3E:
                try memarg()
            case 0x41, 0x42, 0xD0:
                try skipSigned()
            case 0x43:
                try skip(4)
            case 0x44:
                try skip(8)
            case 0xFC:
                try bulk()
            case 0xFD:
                try vector()
            case 0xFE:
                let sub = try u32()
                if sub == 0x03 { _ = try byte() } else { try memarg() }
            default:
                throw .unsupportedOpcode(opcode, nil)
            }
            return false
        }

        private mutating func bulk() throws(Failure) {
            let sub = try u32()
            switch sub {
            case 0...7: break
            case 8, 10, 12, 14:
                _ = try u32()
                _ = try u32()
            case 9, 11, 13, 15, 16, 17: _ = try u32()
            default: throw .unsupportedOpcode(0xFC, sub)
            }
        }

        private mutating func vector() throws(Failure) {
            let sub = try u32()
            switch sub {
            case 0...11, 92, 93: try memarg()
            case 12, 13: try skip(16)
            case 21...34: try skip(1)
            case 84...91:
                try memarg()
                try skip(1)
            case 14...20, 35...83, 94...255: break
            default: throw .unsupportedOpcode(0xFD, sub)
            }
        }
    }
}
