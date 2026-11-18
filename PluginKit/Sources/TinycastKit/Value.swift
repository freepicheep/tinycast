// What crosses to Tinycast: a JSON-shaped value, which a render may also hold nodes and handlers in.

/// A prop, an argument or a host answer. `date` is seconds since 1970; `node` and `handler` exist
/// only in what a plugin renders, and never come back.
public enum PluginValue {
    case string(String)
    case number(Double)
    case bool(Bool)
    case date(Double)
    case null
    case array([PluginValue])
    case object([String: PluginValue])
    case node(PluginNode)
    case handler(@MainActor ([PluginValue]) throws -> Void)

    public var text: String? {
        switch self {
        case .string(let text): text
        case .number(let number): _format(number)
        case .bool(let flag): flag ? "true" : "false"
        default: nil
        }
    }

    public var objectValue: [String: PluginValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    public var arrayValue: [PluginValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    public var numberValue: Double? {
        switch self {
        case .number(let number): number
        case .string(let text): Double(text)
        default: nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let flag): flag
        case .number(let number): number != 0
        case .string(let text): text == "true"
        default: nil
        }
    }

    public subscript(key: String) -> PluginValue? { objectValue?[key] }
}

/// One component of a screen: Raycast's names, such as `List.Item` or `Action.Push`.
public struct PluginNode {
    public var type: String
    /// Keeps a row's identity, and so its selection, when the rows around it change.
    public var key: String?
    public var props: [String: PluginValue]
    public var children: [PluginNode]

    public init(type: String, key: String? = nil, props: [String: PluginValue] = [:], children: [PluginNode] = []) {
        self.type = type
        self.key = key
        self.props = props
        self.children = children
    }
}

// MARK: - JSON

extension PluginValue {
    /// A handler or node written here is a bug: `_tree` writes renders, which register them.
    var json: String {
        var output = ""
        _write(self, to: &output)
        return output
    }

    /// Lenient: what isn't JSON reads as `null`.
    init(json: String) {
        var parser = _JSONParser(bytes: Array(json.utf8))
        self = parser.value() ?? .null
    }
}

func _write(_ value: PluginValue, to output: inout String) {
    switch value {
    case .string(let text): _writeString(text, to: &output)
    case .number(let number): output += number.isFinite ? _format(number) : "null"
    case .bool(let flag): output += flag ? "true" : "false"
    case .date(let seconds):
        output += "{\"$date\":"
        _writeString(_iso8601(seconds), to: &output)
        output += "}"
    case .null, .node, .handler: output += "null"
    case .array(let values):
        output += "["
        for (index, value) in values.enumerated() {
            if index > 0 { output += "," }
            _write(value, to: &output)
        }
        output += "]"
    case .object(let fields):
        output += "{"
        for (index, key) in fields.keys.sorted().enumerated() {
            if index > 0 { output += "," }
            _writeString(key, to: &output)
            output += ":"
            _write(fields[key]!, to: &output)
        }
        output += "}"
    }
}

func _writeString(_ text: String, to output: inout String) {
    output += "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": output += "\\\""
        case "\\": output += "\\\\"
        case "\n": output += "\\n"
        case "\r": output += "\\r"
        case "\t": output += "\\t"
        case _ where scalar.value < 0x20:
            let hex = String(scalar.value, radix: 16)
            output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
        default: output.unicodeScalars.append(scalar)
        }
    }
    output += "\""
}

/// Whole numbers without a fraction, so a count reads "3" and not "3.0".
func _format(_ number: Double) -> String {
    if number == number.rounded(), number.magnitude < 1e15 { return String(Int64(number)) }
    return String(number)
}

struct _JSONParser {
    let bytes: [UInt8]
    var position = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func value() -> PluginValue? {
        skipSpace()
        guard position < bytes.count else { return nil }
        switch bytes[position] {
        case UInt8(ascii: "{"): return object()
        case UInt8(ascii: "["): return array()
        case UInt8(ascii: "\""): return string().map(PluginValue.string)
        case UInt8(ascii: "t"): return literal("true", .bool(true))
        case UInt8(ascii: "f"): return literal("false", .bool(false))
        case UInt8(ascii: "n"): return literal("null", .null)
        default: return number()
        }
    }

    private mutating func skipSpace() {
        while position < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[position]) { position += 1 }
    }

    private mutating func literal(_ word: String, _ value: PluginValue) -> PluginValue? {
        let utf8 = Array(word.utf8)
        guard position + utf8.count <= bytes.count, Array(bytes[position..<position + utf8.count]) == utf8
        else { return nil }
        position += utf8.count
        return value
    }

    private mutating func number() -> PluginValue? {
        let start = position
        while position < bytes.count, "+-0123456789.eE".utf8.contains(bytes[position]) { position += 1 }
        return Double(String(decoding: bytes[start..<position], as: UTF8.self)).map(PluginValue.number)
    }

    private mutating func array() -> PluginValue? {
        position += 1
        var values: [PluginValue] = []
        skipSpace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "]") {
            position += 1
            return .array(values)
        }
        while true {
            guard let value = value() else { return nil }
            values.append(value)
            skipSpace()
            guard position < bytes.count else { return nil }
            let byte = bytes[position]
            position += 1
            if byte == UInt8(ascii: "]") { return .array(values) }
            guard byte == UInt8(ascii: ",") else { return nil }
        }
    }

    private mutating func object() -> PluginValue? {
        position += 1
        var fields: [String: PluginValue] = [:]
        skipSpace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "}") {
            position += 1
            return .object(fields)
        }
        while true {
            skipSpace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: "\""), let key = string() else { return nil }
            skipSpace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { return nil }
            position += 1
            guard let value = value() else { return nil }
            fields[key] = value
            skipSpace()
            guard position < bytes.count else { return nil }
            let byte = bytes[position]
            position += 1
            if byte == UInt8(ascii: "}") {
                if fields.count == 1, let iso = fields["$date"]?.text, let seconds = _parseISO8601(iso) {
                    return .date(seconds)
                }
                return .object(fields)
            }
            guard byte == UInt8(ascii: ",") else { return nil }
        }
    }

    private mutating func string() -> String? {
        position += 1
        var scalars = String.UnicodeScalarView()
        var run = position
        func flush(_ end: Int) {
            scalars.append(contentsOf: String(decoding: bytes[run..<end], as: UTF8.self).unicodeScalars)
        }
        while position < bytes.count {
            let byte = bytes[position]
            if byte == UInt8(ascii: "\"") {
                flush(position)
                position += 1
                return String(scalars)
            }
            guard byte == UInt8(ascii: "\\") else {
                position += 1
                continue
            }
            flush(position)
            position += 1
            guard position < bytes.count else { return nil }
            let escape = bytes[position]
            position += 1
            switch escape {
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "b"): scalars.append("\u{08}")
            case UInt8(ascii: "f"): scalars.append("\u{0C}")
            case UInt8(ascii: "u"):
                guard var code = hex4() else { return nil }
                // A surrogate pair spells one scalar beyond the BMP.
                if (0xD800..<0xDC00).contains(code), position + 1 < bytes.count,
                    bytes[position] == UInt8(ascii: "\\"), bytes[position + 1] == UInt8(ascii: "u")
                {
                    position += 2
                    guard let low = hex4() else { return nil }
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                }
                scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
            default: scalars.append(Unicode.Scalar(escape))
            }
            run = position
        }
        return nil
    }

    private mutating func hex4() -> UInt32? {
        guard position + 4 <= bytes.count,
            let code = UInt32(String(decoding: bytes[position..<position + 4], as: UTF8.self), radix: 16)
        else { return nil }
        position += 4
        return code
    }
}

// MARK: - Dates, as the host's renderer reads them

func _iso8601(_ seconds: Double) -> String {
    let whole = Int64(seconds.rounded(.down))
    let millis = Int((seconds - Double(whole)) * 1000)
    let days = whole >= 0 ? whole / 86_400 : (whole - 86_399) / 86_400
    let secondOfDay = Int(whole - days * 86_400)
    // Howard Hinnant's civil-from-days.
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let dayOfEra = z - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let monthPart = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * monthPart + 2) / 5 + 1
    let month = monthPart < 10 ? monthPart + 3 : monthPart - 9
    let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    func pad(_ value: Int64, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(width - text.count, 0)) + text
    }
    return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(Int64(secondOfDay / 3600), 2)):"
        + "\(pad(Int64(secondOfDay / 60 % 60), 2)):\(pad(Int64(secondOfDay % 60), 2)).\(pad(Int64(millis), 3))Z"
}

/// `2026-11-18T12:00:00.000Z`, with or without the fraction; other offsets aren't read.
func _parseISO8601(_ text: String) -> Double? {
    let parts = text.split(whereSeparator: { "-T:Z.".contains($0) }).map { Int64($0) }
    guard parts.count >= 6, !parts.contains(nil), text.hasSuffix("Z") else { return nil }
    let (year, month, day) = (parts[0]!, parts[1]!, parts[2]!)
    let shiftedYear = month <= 2 ? year - 1 : year
    let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
    let yearOfEra = shiftedYear - era * 400
    let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    let days = era * 146_097 + dayOfEra - 719_468
    var seconds = Double(days * 86_400 + parts[3]! * 3600 + parts[4]! * 60 + parts[5]!)
    if parts.count > 6 { seconds += Double(parts[6]!) / 1000 }
    return seconds
}
