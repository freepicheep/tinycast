// HTTP, through Tinycast: a plugin has no sockets of its own. Needs the `network` permission.

import FoundationEssentials

/// What `fetch(_:)` got back.
public struct Response {
    public let status: Int
    public let statusText: String
    public let headers: [String: String]
    /// Where the request ended up, after redirects.
    public let url: String
    public let data: Data

    public var ok: Bool { (200..<300).contains(status) }
    public var text: String { String(decoding: data, as: UTF8.self) }
}

/// Requests `url` and waits for the whole response. A status that isn't 2xx is not an error: check
/// `ok`.
///
///     let response = try await fetch("https://hacker-news.firebaseio.com/v0/topstories.json")
///     let ids = try JSONDecoder().decode([Int].self, from: response.data)
public func fetch(
    _ url: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil
) async throws -> Response {
    var spec: [String: PluginValue] = [
        "url": .string(url), "method": .string(method), "headers": .object(headers.mapValues(PluginValue.string))
    ]
    if let body { spec["bodyBase64"] = .string(body.base64EncodedString()) }
    let answer = try await _call("fetch", "request", [.object(spec)])
    return Response(
        status: Int(answer["status"]?.numberValue ?? 0), statusText: answer["statusText"]?.text ?? "",
        headers: (answer["headers"]?.objectValue ?? [:]).compactMapValues(\.text),
        url: answer["url"]?.text ?? url,
        data: answer["bodyBase64"]?.text.flatMap { Data(base64Encoded: $0) } ?? Data())
}

/// A form or JSON body as text.
public func fetch(
    _ url: String, method: String, headers: [String: String] = [:], body: String
) async throws -> Response {
    try await fetch(url, method: method, headers: headers, body: Data(body.utf8))
}
