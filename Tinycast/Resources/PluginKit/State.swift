import _TinycastHost

/// A value a command owns. Changing it renders the command again, as in SwiftUI.
@propertyWrapper
public final class State<Value> {
    private var value: Value

    public init(wrappedValue: Value) {
        value = wrappedValue
    }

    public var wrappedValue: Value {
        get { value }
        set {
            value = newValue
            _environment?.invalidate()
        }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { self.wrappedValue }, set: { self.wrappedValue = $0 })
    }
}

/// Read and write access to a value something else owns.
@propertyWrapper
public struct Binding<Value> {
    private let read: () -> Value
    private let write: (Value) -> Void

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        read = get
        write = set
    }

    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { _ in })
    }

    public var wrappedValue: Value {
        get { read() }
        nonmutating set { write(newValue) }
    }

    public var projectedValue: Binding<Value> { self }
}

/// What `@AppStorage` can keep between runs.
public protocol AppStorageValue {
    init?(_storedText: String)
    var _storedText: String { get }
}

extension String: AppStorageValue {
    public init?(_storedText: String) { self = _storedText }
    public var _storedText: String { self }
}

extension Int: AppStorageValue {
    public init?(_storedText: String) { self.init(_storedText) }
    public var _storedText: String { String(self) }
}

extension Double: AppStorageValue {
    public init?(_storedText: String) { self.init(_storedText) }
    public var _storedText: String { String(self) }
}

extension Bool: AppStorageValue {
    public init?(_storedText: String) { self.init(_storedText) }
    public var _storedText: String { self ? "true" : "false" }
}

/// A value kept in the plugin's own storage, which outlives the command; nothing else reads it.
@propertyWrapper
public final class AppStorage<Value: AppStorageValue> {
    private let key: String
    private let defaultValue: Value

    public init(wrappedValue: Value, _ key: String) {
        self.key = key
        defaultValue = wrappedValue
    }

    public var wrappedValue: Value {
        get {
            _environment?.storedValue(forKey: key).flatMap { Value(_storedText: $0) } ?? defaultValue
        }
        set {
            _environment?.setStoredValue(newValue._storedText, forKey: key)
            _environment?.invalidate()
        }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { self.wrappedValue }, set: { self.wrappedValue = $0 })
    }
}
