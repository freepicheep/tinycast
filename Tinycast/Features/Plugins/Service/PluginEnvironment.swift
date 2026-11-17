import Foundation
import Stir

/// What a running plugin asks of Tinycast; the app's coordinator answers, a harness stubs it.
@MainActor
protocol PluginHostServices: AnyObject {
    func showHUD(_ text: String)
    func closeWindow()
    func copy(_ text: String)
    func paste(_ text: String)
    func open(_ url: URL)
    /// A target the manifest doesn't allow; the plugin's own call, so the user hears why.
    func refuseOpen(_ target: String)
}

/// The one host object a plugin's session holds. The kit keeps it in a global, so every call is
/// scoped to the session that made it, and a plugin can only reach its own storage.
@StirExport
@MainActor
final class PluginEnvironment {
    private var name = ""
    private var command = ""
    private var storage: PluginStorage?
    private var urlSchemes: Set<String> = []
    private weak var services: (any PluginHostServices)?
    private var onInvalidate: () -> Void = {}

    private init() {}

    var pluginName: String { name }
    var commandName: String { command }

    /// A `@State` changed: the session renders again once the current script call returns.
    func invalidate() { onInvalidate() }

    func showHUD(_ text: String) { services?.showHUD(text) }
    func closeWindow() { services?.closeWindow() }
    func copy(_ text: String) { services?.copy(text) }
    func paste(_ text: String) { services?.paste(text) }
    func open(_ target: String) {
        guard let url = PluginOpenTarget.resolve(target, schemes: urlSchemes) else {
            services?.refuseOpen(target)
            return
        }
        services?.open(url)
    }

    func storedValue(forKey key: String) -> String? { storage?.value(forKey: key) }
    func setStoredValue(_ value: String?, forKey key: String) {
        storage?.setValue(value, forKey: key)
    }
}

extension PluginEnvironment {
    static func make(
        plugin: String, command: String, urlSchemes: Set<String>, storage: PluginStorage,
        services: any PluginHostServices, onInvalidate: @escaping () -> Void
    ) -> PluginEnvironment {
        let environment = PluginEnvironment()
        environment.name = plugin
        environment.command = command
        environment.storage = storage
        environment.urlSchemes = urlSchemes
        environment.services = services
        environment.onInvalidate = onInvalidate
        return environment
    }

    /// Set once the session exists, since the session owns the environment it hands the script.
    func setInvalidationHandler(_ handler: @escaping () -> Void) {
        onInvalidate = handler
    }

    /// The session is over: a closure the script kept can no longer reach the app.
    func detach() {
        services = nil
        onInvalidate = {}
    }
}
