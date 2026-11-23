// State a command owns, keeps between launches, or reads from its preferences.

import Foundation
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

/// What `@AppStorage` and `LocalStorage` keep: strings, numbers and booleans.
public protocol AppStorageValue {
    init?(_stored: PluginValue)
    var _stored: PluginValue { get }
}

extension String: AppStorageValue {
    public init?(_stored: PluginValue) {
        guard case .string(let value) = _stored else { return nil }
        self = value
    }
    public var _stored: PluginValue { .string(self) }
}

extension Int: AppStorageValue {
    public init?(_stored: PluginValue) {
        guard case .number(let value) = _stored else { return nil }
        self = Int(value)
    }
    public var _stored: PluginValue { .number(Double(self)) }
}

extension Double: AppStorageValue {
    public init?(_stored: PluginValue) {
        guard case .number(let value) = _stored else { return nil }
        self = value
    }
    public var _stored: PluginValue { .number(self) }
}

extension Bool: AppStorageValue {
    public init?(_stored: PluginValue) {
        guard case .bool(let value) = _stored else { return nil }
        self = value
    }
    public var _stored: PluginValue { .bool(self) }
}

/// A value kept in the plugin's `LocalStorage`, which outlives the command; nothing else reads it.
@propertyWrapper
public final class AppStorage<Value: AppStorageValue> {
    private let key: String
    private let defaultValue: Value

    public init(wrappedValue: Value, _ key: String) {
        self.key = key
        defaultValue = wrappedValue
    }

    public var wrappedValue: Value {
        get { _environment?.storedValue(forKey: key).flatMap { Value(_stored: $0) } ?? defaultValue }
        set {
            _environment?.setStoredValue(newValue._stored, forKey: key)
            _environment?.invalidate()
        }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { self.wrappedValue }, set: { self.wrappedValue = $0 })
    }
}

/// What a preference reads as.
public protocol PreferenceValue {
    init?(_preference: PluginValue)
}

extension String: PreferenceValue {
    public init?(_preference: PluginValue) {
        guard let text = _preference.text else { return nil }
        self = text
    }
}

extension Bool: PreferenceValue {
    public init?(_preference: PluginValue) {
        switch _preference {
        case .bool(let value): self = value
        case .string(let value): self = value == "true"
        default: return nil
        }
    }
}

extension Int: PreferenceValue {
    public init?(_preference: PluginValue) {
        switch _preference {
        case .number(let value): self = Int(value)
        case .string(let value):
            guard let number = Int(value) else { return nil }
            self = number
        default: return nil
        }
    }
}

extension Double: PreferenceValue {
    public init?(_preference: PluginValue) {
        switch _preference {
        case .number(let value): self = value
        case .string(let value):
            guard let number = Double(value) else { return nil }
            self = number
        default: return nil
        }
    }
}

/// A preference the manifest declares, as the user set it in Settings › Plugins: an application,
/// a file or a folder reads as its path.
///
///     @Preference("apiKey") var apiKey: String
@propertyWrapper
public struct Preference<Value: PreferenceValue> {
    private let name: String
    private let fallback: Value?

    public init(_ name: String) {
        self.name = name
        fallback = nil
    }

    public init(wrappedValue: Value, _ name: String) {
        self.name = name
        fallback = wrappedValue
    }

    public var wrappedValue: Value {
        if let raw = _launch?.preferences[name], let value = Value(_preference: raw) { return value }
        if let fallback { return fallback }
        fatalError("Manifest.swift declares no preference “\(name)” of this type")
    }
}

/// Every preference's value, by name.
public func getPreferenceValues() -> [String: PluginValue] {
    _launch?.preferences ?? [:]
}
