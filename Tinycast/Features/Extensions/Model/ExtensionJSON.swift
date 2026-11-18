import Foundation

/// The JSON every engine and host call speaks: arguments arrive as an array, answers leave as text.
enum ExtensionJSON {
    static func array(from json: String) -> [Any] {
        guard let data = json.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        return array
    }

    /// Fragment-tolerant encoding: host results are frequently bare strings, numbers or nil.
    static func string(from value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
