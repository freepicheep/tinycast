import Foundation

/// Which of the Extensions host's APIs a plugin's call may reach. A plugin has no files, sockets or
/// processes of its own, so this one check, made before every call it sends, is the whole of what
/// its permissions grant. An API not listed here doesn't exist for plugins.
enum PluginHostPolicy {
    /// Nil when the call may go ahead; otherwise why not, which the plugin's call throws.
    static func refusal(
        api: String, method: String, arguments: [RenderValue], manifest: PluginManifest
    ) -> String? {
        func needs(_ permission: PluginPermission) -> String? {
            manifest.permissions.contains(permission)
                ? nil : "\(api).\(method) needs the “\(permission.rawValue)” permission in the manifest"
        }
        switch (api, method) {
        case ("storage", _), ("cache", _), ("form", "store"), ("window", _), ("feedback", _), ("oauth", _):
            return nil
        case ("clipboard", "copy"), ("clipboard", "paste"), ("clipboard", "clear"):
            return nil
        case ("clipboard", "readText"), ("clipboard", "read"):
            return needs(.clipboard)
        case ("fetch", _):
            // A Unix socket is a local service's own door, not the network the permission names.
            if arguments.first?.objectValue?["socketPath"] != nil { return "a plugin can't reach a Unix socket" }
            return needs(.network)
        case ("websocket", _), ("dns", _):
            return needs(.network)
        case ("system", "selectedText"), ("system", "selectedFinderItems"):
            return needs(.selection)
        case ("system", "open"):
            let target = arguments.first?.stringValue ?? ""
            guard PluginOpenTarget.resolve(target, schemes: manifest.urlSchemes) != nil else {
                let scheme = URL(string: target)?.scheme ?? target
                return "the plugin can't open \(scheme) links: its manifest doesn't list that scheme"
            }
            return nil
        case ("system", "launchCommand"):
            let other = arguments.first?.objectValue?["extensionName"]?.stringValue
            return other == nil || other == manifest.hostName ? nil : "a plugin can launch only its own commands"
        case ("system", "openWith"), ("system", "showInFinder"), ("system", "trash"), ("system", "applications"),
            ("system", "defaultApplication"), ("system", "frontmostApplication"),
            ("system", "updateCommandMetadata"):
            return nil
        default:
            return "\(api).\(method) isn't available to plugins"
        }
    }
}
