import Foundation
import Scrift

/// A plain value a plugin passes or reads: a preference, a launch's context, a stored value.
@ScriftExport
indirect enum PluginValue {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([PluginValue])
    case object([String: PluginValue])
    case null
}

/// What a command starts with: its launch's arguments and context, and its preferences.
@ScriftExport
struct PluginLaunch {
    var commandName: String
    /// True when the command's schedule ran it, not the user.
    var isBackground: Bool
    var arguments: [String: String]
    var preferences: [String: PluginValue]
    var fallbackText: String?
    var launchContext: [String: PluginValue]
    var isDarkAppearance: Bool
}

extension PluginLaunch: Codable, Equatable, Sendable {}

/// JSON's own shape: `"a"`, `1`, `true`, `[…]`, `{…}`, `null`.
extension PluginValue: Codable, Equatable, Sendable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let values = try? container.decode([PluginValue].self) {
            self = .array(values)
        } else {
            self = .object(try container.decode([String: PluginValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let text): try container.encode(text)
        case .number(let number): try container.encode(number)
        case .bool(let flag): try container.encode(flag)
        case .array(let values): try container.encode(values)
        case .object(let fields): try container.encode(fields)
        case .null: try container.encodeNil()
        }
    }
}
