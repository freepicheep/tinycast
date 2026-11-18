/// What runs an installed extension's commands. A Raycast bundle runs in JavaScriptCore; a plugin
/// runs in the engine its feature supplies. Everything above the runtime — the palette, the
/// background and menu-bar lanes, the host APIs, the renderer — is the same for both.
enum ExtensionEngine: Sendable, Hashable {
    case javascript
    case plugin
}
