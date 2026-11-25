import AppKit
import Foundation

/// One running command's host calls, answered by the app for the plugin that made them: its
/// grants decide what `open` reaches, and its name is the namespace for its tokens. A background
/// or menu-bar run shows no dialogs, toasts or HUDs.
@MainActor
final class PluginHostBridge: PluginHostAPI {
    enum Kind {
        case palette
        case action
        case background
        case menuBar
    }

    private weak var host: PluginHost?
    private let plugin: PluginManifest
    private let command: PluginCommandRef
    let kind: Kind

    init(host: PluginHost, plugin: PluginManifest, command: PluginCommandRef, kind: Kind) {
        self.host = host
        self.plugin = plugin
        self.command = command
        self.kind = kind
    }

    private var isQuiet: Bool { kind == .background || kind == .menuBar }

    func sessionEnded() {}

    /// The helper is plugin code's process, so a grant is checked where the answer is made too.
    private func requireSelection() throws {
        guard plugin.permissions.contains(.selection) else {
            throw PluginHostError(message: "Manifest.swift doesn't ask for the selection permission.")
        }
    }

    func perform(_ call: PluginHostCall) async throws -> PluginHostAnswer {
        guard let host else { throw PluginHostError.noSession }
        let coordinator = host.coordinator
        switch call {
        case .copy(let text, let concealed):
            PluginEffects.copy(text, concealed: concealed)
        case .paste(let text):
            coordinator?.paste(text)
        case .clearClipboard:
            NSPasteboard.general.clearContents()
        case .open(let target, let application):
            guard let url = PluginOpenTarget.resolve(target, schemes: plugin.urlSchemes) else {
                throw PluginHostError(message: "This plugin can't open “\(target)”.")
            }
            PluginEffects.open(url, application: application)
        case .showInFinder(let path):
            PluginEffects.reveal(path)
        case .openWith(let path):
            await coordinator?.openWith(path: path)
        case .trash(let paths):
            PluginEffects.trash(paths)
        case .showHUD(let text):
            if !isQuiet { coordinator?.showMessage(text, isError: false) }
        case .showToast(let toast):
            return .int(isQuiet ? 0 : host.present(toast, from: kind))
        case .updateToast(let id, let toast):
            host.update(toast: id, with: toast)
        case .hideToast(let id):
            host.hide(toast: id)
        case .confirm(let alert):
            guard !isQuiet, let coordinator else { return .bool(false) }
            return .bool(await coordinator.confirm(alert))
        case .closeMainWindow:
            if !isQuiet { coordinator?.closePalette() }
        case .popToRoot:
            if kind == .palette { coordinator?.popToRoot() }
        case .clearSearchBar:
            if kind == .palette { coordinator?.clearSearchBar() }
        case .openPreferences:
            coordinator?.showSettings(for: command.plugin)
        case .launchCommand(let name, let background, let arguments, let context):
            guard plugin.commands.contains(where: { $0.name == name }) else {
                throw PluginHostError(message: "Manifest.swift declares no command “\(name)”.")
            }
            host.launch(
                PluginCommandRef(plugin: plugin.name, command: name), background: background, arguments: arguments,
                context: context)
        case .updateCommandMetadata(let subtitle):
            host.updateSubtitle(subtitle, for: command)
        case .applications(let path):
            return .applications(PluginEffects.applications(forPath: path, all: coordinator?.applicationURLs ?? []))
        case .defaultApplication(let path):
            return .application(PluginEffects.defaultApplication(for: path))
        case .frontmostApplication:
            let app = coordinator?.pasteTarget ?? NSWorkspace.shared.frontmostApplication
            return .application(app?.bundleURL.map(PluginEffects.describe))
        case .authorize(let url, let scheme):
            guard !isQuiet else { throw PluginHostError(message: "A background run can't sign in.") }
            guard let request = URL(string: url) else { throw URLError(.badURL) }
            return .text(try await host.signIn(url: request, callbackScheme: scheme).absoluteString)
        case .setTokens(let provider, let tokens):
            host.store.setTokens(tokens, plugin: plugin.name, provider: provider)
        case .tokens(let provider):
            return .tokens(host.store.tokens(plugin: plugin.name, provider: provider))
        case .selectedText:
            try requireSelection()
            return .text(PluginEffects.selectedText(in: coordinator?.pasteTarget) ?? "")
        case .selectedFinderItems:
            try requireSelection()
            return .texts(PluginEffects.finderSelection())
        }
        return .none
    }
}
