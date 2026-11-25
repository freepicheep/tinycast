// State a command owns, keeps between launches, reads from its preferences or its environment.

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

/// A value kept in the plugin's own storage, which outlives the command and is shared by its
/// commands: any `Codable` value, stored as JSON.
@propertyWrapper
public final class AppStorage<Value: Codable> {
    private let key: String
    private let defaultValue: Value

    public init(wrappedValue: Value, _ key: String) {
        self.key = key
        defaultValue = wrappedValue
    }

    public var wrappedValue: Value {
        get {
            guard let stored = _environment?.storedValue(forKey: key),
                let value = try? JSONDecoder().decode(Value.self, from: Data(stored.utf8))
            else { return defaultValue }
            return value
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            _environment?.setStoredValue(String(decoding: data, as: UTF8.self), forKey: key)
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
        switch _preference {
        case .string(let value): self = value
        case .number(let value): self = value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): self = value ? "true" : "false"
        default: return nil
        }
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

// MARK: - The environment

public enum ColorScheme {
    case light
    case dark
}

/// Leaves the screen a `NavigationLink` pushed: `@Environment(\.dismiss) var dismiss`, then `dismiss()`.
public struct DismissAction {
    public func callAsFunction() {
        _ = _tinycastPop()
    }
}

/// Opens a web address, a file path or an app link the manifest allows.
public struct OpenURLAction {
    public func callAsFunction(_ url: URL) {
        open(url.absoluteString)
    }
}

/// What `@Environment` reads.
public struct EnvironmentValues {
    public var dismiss: DismissAction { DismissAction() }
    public var openURL: OpenURLAction { OpenURLAction() }
    /// The palette's appearance when the command started.
    public var colorScheme: ColorScheme { (_launch?.isDarkAppearance ?? false) ? .dark : .light }
}

/// A value from the command's environment: `@Environment(\.dismiss) private var dismiss`.
@propertyWrapper
public struct Environment<Value> {
    private let keyPath: KeyPath<EnvironmentValues, Value>

    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {
        self.keyPath = keyPath
    }

    public var wrappedValue: Value { EnvironmentValues()[keyPath: keyPath] }
}
