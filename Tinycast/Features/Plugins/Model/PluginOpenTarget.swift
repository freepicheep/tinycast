import Foundation

/// What a plugin's `open` may reach: a web or mail address, a file, or an app link scheme its
/// manifest declares. Decided here, before anything reaches `NSWorkspace`.
enum PluginOpenTarget {
    static let alwaysAllowed: Set<String> = ["http", "https", "mailto"]

    /// Tinycast's own links run commands, and a file URL is spelled as a path instead.
    private static let neverAllowed: Set<String> = ["tinycast", "tinycast-dev", "raycast", "com.raycast", "file"]

    /// RFC 3986's scheme grammar, minus the schemes no manifest may claim.
    static func isOpenableScheme(_ scheme: String) -> Bool {
        let lowered = scheme.lowercased()
        guard let first = lowered.unicodeScalars.first, ("a"..."z").contains(first), lowered.count <= 64,
            !neverAllowed.contains(lowered)
        else { return false }
        return lowered.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || "+-.".unicodeScalars.contains($0)
        }
    }

    /// The URL to open, or nil when the target is neither a path nor an allowed address.
    static func resolve(_ target: String, schemes: Set<String>) -> URL? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return URL(filePath: (trimmed as NSString).expandingTildeInPath)
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            alwaysAllowed.contains(scheme) || (schemes.contains(scheme) && isOpenableScheme(scheme))
        else { return nil }
        return url
    }
}
