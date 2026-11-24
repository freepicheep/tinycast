import Foundation

/// What a plugin session reads and writes synchronously, as a getter must: the app's
/// `ExtensionStorage` when the session runs in the app, or `PluginStorageMirror`, the plugin
/// helper's copy of one plugin's part of it, whose writes go back to the app. The app stays the
/// only writer of the files, so a preference set in Settings can't race a plugin's own write.
@MainActor
protocol PluginStorage: AnyObject {
    func localStorageValue(extension name: String, key: String) -> ExtensionStorage.StoredValue?
    func allLocalStorage(extension name: String) -> [String: ExtensionStorage.StoredValue]
    func setLocalStorage(extension name: String, key: String, value: ExtensionStorage.StoredValue)
    func removeLocalStorage(extension name: String, key: String)
    func clearLocalStorage(extension name: String)
    func formValues(extension name: String, command: String) -> [String: String]
    func setFormValues(extension name: String, command: String, values: [String: String])
    func caches(extension name: String) -> [String: [String: String]]
    func setCache(extension name: String, namespace: String, key: String?, value: String?)
}

extension ExtensionStorage: PluginStorage {}

/// One plugin's storage as a launch found it, and every write since. Sent to the helper with the
/// launch; the helper's writes come back as `PluginStorageWrite`s, applied in order.
struct PluginStorageSnapshot: Codable, Sendable, Equatable {
    var localStorage: [String: ExtensionStorage.StoredValue] = [:]
    var caches: [String: [String: String]] = [:]
    var formValues: [String: [String: String]] = [:]

    @MainActor
    init(of name: String, in storage: ExtensionStorage) {
        localStorage = storage.allLocalStorage(extension: name)
        caches = storage.caches(extension: name)
        formValues = storage.formValuesByCommand(extension: name)
    }

    init() {}
}

/// A write a plugin made in the helper, for the app to make to its `ExtensionStorage`.
enum PluginStorageWrite: Codable, Sendable, Equatable {
    case setLocal(key: String, value: ExtensionStorage.StoredValue)
    case removeLocal(key: String)
    case clearLocal
    case setFormValues(command: String, values: [String: String])
    case setCache(namespace: String, key: String?, value: String?)

    @MainActor
    func apply(to storage: ExtensionStorage, extension name: String) {
        switch self {
        case .setLocal(let key, let value): storage.setLocalStorage(extension: name, key: key, value: value)
        case .removeLocal(let key): storage.removeLocalStorage(extension: name, key: key)
        case .clearLocal: storage.clearLocalStorage(extension: name)
        case .setFormValues(let command, let values):
            storage.setFormValues(extension: name, command: command, values: values)
        case .setCache(let namespace, let key, let value):
            storage.setCache(extension: name, namespace: namespace, key: key, value: value)
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

    func localStorageValue(extension name: String, key: String) -> ExtensionStorage.StoredValue? {
        snapshot.localStorage[key]
    }

    func allLocalStorage(extension name: String) -> [String: ExtensionStorage.StoredValue] {
        snapshot.localStorage
    }

    func setLocalStorage(extension name: String, key: String, value: ExtensionStorage.StoredValue) {
        snapshot.localStorage[key] = value
        send(.setLocal(key: key, value: value))
    }

    func removeLocalStorage(extension name: String, key: String) {
        snapshot.localStorage.removeValue(forKey: key)
        send(.removeLocal(key: key))
    }

    func clearLocalStorage(extension name: String) {
        snapshot.localStorage = [:]
        send(.clearLocal)
    }

    func formValues(extension name: String, command: String) -> [String: String] {
        snapshot.formValues[command] ?? [:]
    }

    func setFormValues(extension name: String, command: String, values: [String: String]) {
        snapshot.formValues[command, default: [:]].merge(values) { $1 }
        send(.setFormValues(command: command, values: values))
    }

    func caches(extension name: String) -> [String: [String: String]] {
        snapshot.caches
    }

    func setCache(extension name: String, namespace: String, key: String?, value: String?) {
        if let key {
            var bucket = snapshot.caches[namespace] ?? [:]
            if let value { bucket[key] = value } else { bucket.removeValue(forKey: key) }
            snapshot.caches[namespace] = bucket
        } else {
            snapshot.caches[namespace] = [:]
        }
        send(.setCache(namespace: namespace, key: key, value: value))
    }
}
