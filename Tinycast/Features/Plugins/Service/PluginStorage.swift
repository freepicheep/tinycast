import Foundation

/// What a plugin session reads and writes synchronously, as a getter must: each `@AppStorage`
/// value as JSON text, by key. The app's `PluginStore` when the session runs in the app, or
/// `PluginStorageMirror`, the plugin helper's copy of one plugin's part of it, whose writes go back
/// to the app. The app stays the only writer of the files.
@MainActor
protocol PluginStorage: AnyObject {
    func value(plugin: String, key: String) -> String?
    func values(plugin: String) -> [String: String]
    /// Nil removes the key.
    func setValue(_ value: String?, plugin: String, key: String)
    func clearValues(plugin: String)
}

/// One plugin's storage as a launch found it. Sent to the helper with the launch; the helper's
/// writes come back as `PluginStorageWrite`s, applied in order.
struct PluginStorageSnapshot: Codable, Sendable, Equatable {
    var values: [String: String] = [:]

    @MainActor
    init(of plugin: String, in storage: any PluginStorage) {
        values = storage.values(plugin: plugin)
    }

    init(values: [String: String] = [:]) {
        self.values = values
    }
}

/// A write a plugin made in the helper, for the app to make to its own storage.
enum PluginStorageWrite: Codable, Sendable, Equatable {
    case set(key: String, value: String?)
    case clear

    @MainActor
    func apply(to storage: any PluginStorage, plugin: String) {
        switch self {
        case .set(let key, let value): storage.setValue(value, plugin: plugin, key: key)
        case .clear: storage.clearValues(plugin: plugin)
        }
    }
}

/// The helper's copy of one plugin's storage: reads answer from the snapshot, which each write
/// updates before `send` passes it on, so a plugin reads back what it wrote at once.
@MainActor
final class PluginStorageMirror: PluginStorage {
    private var snapshot: PluginStorageSnapshot
    private let send: (PluginStorageWrite) -> Void

    init(_ snapshot: PluginStorageSnapshot, send: @escaping (PluginStorageWrite) -> Void) {
        self.snapshot = snapshot
        self.send = send
    }

    func value(plugin: String, key: String) -> String? { snapshot.values[key] }

    func values(plugin: String) -> [String: String] { snapshot.values }

    func setValue(_ value: String?, plugin: String, key: String) {
        snapshot.values[key] = value
        send(.set(key: key, value: value))
    }

    func clearValues(plugin: String) {
        snapshot.values = [:]
        send(.clear)
    }
}

/// Storage that lives only as long as the object: for checks and tools, not the app.
@MainActor
final class PluginMemoryStorage: PluginStorage {
    private var stored: [String: [String: String]] = [:]

    init() {}

    func value(plugin: String, key: String) -> String? { stored[plugin]?[key] }
    func values(plugin: String) -> [String: String] { stored[plugin] ?? [:] }
    func setValue(_ value: String?, plugin: String, key: String) { stored[plugin, default: [:]][key] = value }
    func clearValues(plugin: String) { stored[plugin] = nil }
}
