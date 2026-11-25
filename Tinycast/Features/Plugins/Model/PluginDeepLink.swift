import Foundation

/// `tinycast://plugins/<plugin>/<command>`, with optional `arguments`, `fallbackText`,
/// `launchType=background` and `context` (a JSON object) in its query.
struct PluginDeepLink: Sendable, Equatable {
    let command: PluginCommandRef
    let arguments: [String: String]
    let fallbackText: String?
    let isBackground: Bool
    let launchContext: [String: PluginValue]

    static func claims(_ url: URL) -> Bool {
        ["tinycast", "tinycast-dev"].contains(url.scheme?.lowercased() ?? "") && url.host?.lowercased() == "plugins"
    }

    static func url(_ command: PluginCommandRef, arguments: [String: String], scheme: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "plugins"
        components.path = "/\(command.plugin)/\(command.command)"
        if !arguments.isEmpty, let encoded = encoded(arguments) {
            components.percentEncodedQueryItems = [URLQueryItem(name: "arguments", value: encoded)]
        }
        return components.url
    }

    /// Strict, so `parse` reads back exactly what was typed.
    private static func encoded(_ arguments: [String: String]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return (try? encoder.encode(arguments))
            .map { String(decoding: $0, as: UTF8.self) }
            .flatMap { $0.addingPercentEncoding(withAllowedCharacters: unreserved) }
    }

    static func parse(_ url: URL) -> PluginDeepLink? {
        guard claims(url) else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }.map { $0.removingPercentEncoding ?? $0 }
        guard segments.count == 2, !segments[0].contains("."), !segments[1].isEmpty else { return nil }
        var arguments: [String: String] = [:]
        var fallbackText: String?
        var isBackground = false
        var launchContext: [String: PluginValue] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            switch item.name.lowercased() {
            case "arguments": arguments = item.value.map(parseArguments) ?? [:]
            case "fallbacktext": fallbackText = item.value
            case "launchtype": isBackground = item.value?.lowercased() == "background"
            case "context": launchContext = item.value.map(parseContext) ?? [:]
            default: break
            }
        }
        return PluginDeepLink(
            command: PluginCommandRef(plugin: segments[0], command: segments[1]), arguments: arguments,
            fallbackText: fallbackText, isBackground: isBackground, launchContext: launchContext)
    }

    static func parseContext(_ raw: String) -> [String: PluginValue] {
        (try? JSONDecoder().decode([String: PluginValue].self, from: Data(raw.utf8))) ?? [:]
    }

    /// One JSON object; a number or a flag reads as its text, and anything else means no arguments.
    static func parseArguments(_ raw: String) -> [String: String] {
        guard let values = try? JSONDecoder().decode([String: PluginValue].self, from: Data(raw.utf8)) else {
            return [:]
        }
        return values.compactMapValues { value in
            switch value {
            case .string(let text): text
            case .bool(let flag): flag ? "true" : "false"
            case .number(let number):
                number == number.rounded() && number.magnitude < 1e15 ? String(Int64(number)) : String(number)
            case .null: ""
            case .array, .object: nil
            }
        }
    }
}
