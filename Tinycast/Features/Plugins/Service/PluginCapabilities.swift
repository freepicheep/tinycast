import AppKit
import Foundation
import Scrift
import ScriftFoundation

/// The APIs a permission grants. Each keeps Foundation's or AppKit's own spelling, so a plugin reads
/// as the Swift its author already writes, and is absent from scripts that weren't granted it.
enum PluginCapabilities {
    /// A session's host modules: the kit's own and what each permission grants.
    @MainActor
    static func modules(for permissions: Set<PluginPermission>) -> [ScriftHostModule] {
        var modules = [hostModule, foundation(network: permissions.contains(.network))]
        if permissions.contains(.clipboard) { modules.append(appKit) }
        if permissions.contains(.selection) { modules.append(selectionHost) }
        return modules
    }

    /// The host types every plugin's kit renders into; plugins see them only through the kit.
    static var hostModule: ScriftHostModule {
        ScriftHostModule(
            "_TinycastHost",
            exports: [
                PluginNode.self, PluginValue.self, PluginLaunch.self, PluginEnvironment.self, PluginOAuthRequest.self,
                PluginOAuthTokens.self,
                PluginApplication.self
            ])
    }

    static var selectionHost: ScriftHostModule {
        ScriftHostModule("_TinycastSelection", exports: [PluginSelection.self])
    }

    /// `import Selection`, with the selection permission: Swift source over the host object, so a
    /// plugin calls `selectedText()` as a function and the host knows whose session asks.
    @MainActor
    static func loadSelection(into context: ScriftContext, hostAPI: ExtensionHostAPI) throws {
        let module = try context.load(
            files: [SourceFile(name: "Selection.swift", text: selectionSource)], moduleName: "Selection")
        try module.run(limits: ScriftPluginRuntime.limits)
        let bind = try module.function(
            "_bind", as: ((PluginSelection) throws -> Void).self, limits: ScriftPluginRuntime.limits)
        try bind(PluginSelection(hostAPI: hostAPI))
    }

    private static let selectionSource = """
        import Foundation
        import _TinycastSelection

        var _host: _SelectionHost? = nil

        func _bind(_ host: _SelectionHost) { _host = host }

        /// The text selected in the app that was in front before the palette opened.
        public func selectedText() async throws -> String {
            guard let host = _host else { return "" }
            return try await host.text()
        }

        /// The files and folders selected in Finder.
        public func selectedFinderItems() async throws -> [URL] {
            guard let host = _host else { return [] }
            return try await host.finderItems()
        }
        """

    /// `import Foundation`: ScriftFoundation's slice, plus `URLSession` with the network permission.
    static func foundation(network: Bool) -> ScriftHostModule {
        let base = ScriftFoundation.module
        guard network else { return base }
        return ScriftHostModule(
            base.name,
            types: base.types + [
                PluginURLSession.scriftExports, PluginHTTPURLResponse.scriftExports,
                PluginURLRequest.scriftExports
            ])
    }

    /// `import AppKit`: the general pasteboard's text, with the clipboard permission.
    static var appKit: ScriftHostModule {
        ScriftHostModule("AppKit", exports: [PluginPasteboard.self, PluginPasteboardType.self])
    }

    /// Larger bodies fail the request rather than land in a plugin's memory.
    static let maximumResponseSize = 16 << 20

    /// Private and ephemeral, like every networked feature: nothing a plugin fetches is cached.
    nonisolated static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()
}

@ScriftExport(as: "URLSession")
final class PluginURLSession {
    private init() {}

    static var shared: PluginURLSession { PluginURLSession() }

    func data(from url: URL) async throws -> (Data, PluginHTTPURLResponse) {
        try await data(for: PluginURLRequest(url: url))
    }

    func data(for request: PluginURLRequest) async throws -> (Data, PluginHTTPURLResponse) {
        guard let scheme = request.url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { throw PluginNetworkError.unsupportedURL(request.url.absoluteString) }
        var native = URLRequest(url: request.url)
        native.httpMethod = request.httpMethod
        native.httpBody = request.httpBody
        native.allHTTPHeaderFields = request.allHTTPHeaderFields
        let (data, response) = try await PluginCapabilities.transport.data(for: native)
        guard data.count <= PluginCapabilities.maximumResponseSize else {
            throw PluginNetworkError.tooLarge(data.count)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PluginNetworkError.unsupportedURL(request.url.absoluteString)
        }
        return (data, PluginHTTPURLResponse(http))
    }
}

@ScriftExport(as: "HTTPURLResponse")
final class PluginHTTPURLResponse {
    private let response: HTTPURLResponse

    fileprivate init(_ response: HTTPURLResponse) {
        self.response = response
    }

    var statusCode: Int { response.statusCode }
    var url: URL? { response.url }
    var mimeType: String? { response.mimeType }

    func value(forHTTPHeaderField field: String) -> String? {
        response.value(forHTTPHeaderField: field)
    }
}

@ScriftExport(as: "URLRequest")
struct PluginURLRequest {
    var url: URL
    var httpMethod: String?
    var httpBody: Data?
    var allHTTPHeaderFields: [String: String]?

    init(url: URL) {
        self.url = url
        httpMethod = nil
        httpBody = nil
        allHTTPHeaderFields = nil
    }

    mutating func setValue(_ value: String?, forHTTPHeaderField field: String) {
        var fields = allHTTPHeaderFields ?? [:]
        fields[field] = value
        allHTTPHeaderFields = fields
    }
}

@ScriftExport(as: "NSPasteboard")
@MainActor
final class PluginPasteboard {
    private init() {}

    static var general: PluginPasteboard { PluginPasteboard() }

    /// Spelled as AppKit spells it, so `string(forType: .string)` reads the same in a plugin.
    func string(forType type: PluginPasteboardType) -> String? {
        switch type {
        case .string: NSPasteboard.general.string(forType: .string)
        }
    }
}

@ScriftExport(as: "PasteboardType")
enum PluginPasteboardType {
    case string
}

enum PluginNetworkError: Error, CustomStringConvertible {
    case unsupportedURL(String)
    case tooLarge(Int)

    var description: String {
        switch self {
        case .unsupportedURL(let url): "only http and https URLs can be fetched, not \(url)"
        case .tooLarge(let size): "the response is \(size) bytes; plugins can fetch up to 16 MB"
        }
    }
}

@ScriftExport(as: "_SelectionHost")
@MainActor
final class PluginSelection {
    private let hostAPI: ExtensionHostAPI

    fileprivate init(hostAPI: ExtensionHostAPI) {
        self.hostAPI = hostAPI
    }

    func text() async throws -> String {
        let json = try await hostAPI.perform(api: "system", method: "selectedText", arguments: [])
        return RenderValue.arguments(from: "[\(json)]").first?.stringValue ?? ""
    }

    func finderItems() async throws -> [URL] {
        let json = try await hostAPI.perform(api: "system", method: "selectedFinderItems", arguments: [])
        return RenderValue.arguments(from: json).compactMap {
            $0.objectValue?["path"]?.stringValue.map { URL(filePath: $0) }
        }
    }
}
