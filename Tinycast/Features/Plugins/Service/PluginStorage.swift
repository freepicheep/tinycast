import Foundation

/// One plugin's `@AppStorage` values: a small JSON file of strings, written on every change.
@MainActor
final class PluginStorage {
    private let fileURL: URL
    private var values: [String: String]

    /// Values past this many bytes in total are refused, so a plugin can't fill the disk.
    static let capacity = 1 << 20

    init(fileURL: URL) {
        self.fileURL = fileURL
        values =
            (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    func value(forKey key: String) -> String? { values[key] }

    func setValue(_ value: String?, forKey key: String) {
        guard values[key] != value else { return }
        var next = values
        next[key] = value
        guard next.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= Self.capacity
        else { return }
        values = next
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(values).write(to: fileURL, options: .atomic)
    }
}
