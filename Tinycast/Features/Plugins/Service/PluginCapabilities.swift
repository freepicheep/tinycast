import AppKit
import Foundation
import Stir
import StirFoundation

/// The APIs a permission grants. Each keeps Foundation's or AppKit's own spelling, so a plugin reads
/// as the Swift its author already writes, and is absent from scripts that weren't granted it.
enum PluginCapabilities {
    /// `import Foundation`: StirFoundation's slice, plus `URLSession` with the network permission.
    static func foundation(network: Bool) -> StirHostModule {
        let base = StirFoundation.module
        guard network else { return base }
        return StirHostModule(
            base.name,
            types: base.types + [
                PluginURLSession.stirExports, PluginHTTPURLResponse.stirExports,
                PluginURLRequest.stirExports
            ])
    }

    /// `import AppKit`: the general pasteboard's text, with the clipboard permission.
    static var appKit: StirHostModule {
        StirHostModule("AppKit", exports: [PluginPasteboard.self, PluginPasteboardType.self])
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

@StirExport(as: "URLSession")
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

@StirExport(as: "HTTPURLResponse")
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

@StirExport(as: "URLRequest")
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

@StirExport(as: "NSPasteboard")
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

@StirExport(as: "PasteboardType")
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
