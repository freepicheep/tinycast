// Signing in to a service with OAuth 2.0 and PKCE, the way Raycast's `OAuth.PKCEClient` does: the
// kit builds the request, Tinycast runs the browser sign-in and keeps each provider's tokens.

import FoundationEssentials

public enum OAuth {
    /// Where the provider sends the user back. Register this redirect URI with the provider.
    public enum Redirect {
        /// Tinycast's own: `tinycast://oauth?plugin=<name>`.
        case app
        /// A custom-scheme URI the provider requires, such as `com.example.app:/oauth`.
        case custom(String)
    }

    /// A sign-in about to start: open it with `PKCEClient.authorize(_:)`, and keep `codeVerifier`
    /// for the token exchange.
    public struct AuthorizationRequest {
        public let url: String
        public let codeVerifier: String
        public let codeChallenge: String
        public let state: String
        public let redirectURI: String
    }

    /// What a provider granted, as `PKCEClient.getTokens()` returns it.
    public struct TokenSet {
        public let accessToken: String
        public let refreshToken: String?
        public let idToken: String?
        /// Seconds the access token lasts from `updatedAt`, if the provider said.
        public let expiresIn: Double?
        public let scope: String?
        public let updatedAt: Date

        /// True ten seconds before the access token expires; never when the provider gave no expiry.
        public var isExpired: Bool {
            guard let expiresIn else { return false }
            return Date() >= updatedAt.addingTimeInterval(expiresIn - 10)
        }
    }

    public enum OAuthError: Error, CustomStringConvertible {
        case invalidEndpoint(String)
        case provider(String)
        case mismatchedState(String)
        case noCode(String)

        public var description: String {
            switch self {
            case .invalidEndpoint(let endpoint): "An OAuth endpoint must be an https URL, not \(endpoint)."
            case .provider(let message): message
            case .mismatchedState(let provider): "\(provider) sign-in returned a mismatched state."
            case .noCode(let provider): "\(provider) sign-in returned no authorization code."
            }
        }
    }

    /// Runs the browser sign-in and keeps each provider's tokens in the plugin's storage. The token
    /// exchange is the plugin's: a `fetch` with the code and `codeVerifier`, which needs the
    /// `network` permission.
    ///
    ///     let client = OAuth.PKCEClient(providerName: "GitHub")
    ///     let request = try client.authorizationRequest(
    ///         endpoint: "https://github.com/login/oauth/authorize", clientID: id, scope: "repo")
    ///     let code = try await client.authorize(request)
    public final class PKCEClient {
        public let providerName: String
        /// The key the tokens are kept under; the provider's name unless given.
        public let providerID: String
        let redirect: Redirect

        public init(providerName: String, providerID: String? = nil, redirect: Redirect = .app) {
            self.providerName = providerName
            self.providerID = providerID ?? providerName
            self.redirect = redirect
        }

        public func authorizationRequest(
            endpoint: String, clientID: String, scope: String, extraParameters: [String: String] = [:]
        ) throws -> AuthorizationRequest {
            guard endpoint.hasPrefix("https://") else { throw OAuthError.invalidEndpoint(endpoint) }
            let verifier = _randomURLSafe(32)
            let challenge = _base64URL(_sha256(Array(verifier.utf8)))
            let state = _randomURLSafe(16)
            let redirectURI: String
            switch redirect {
            case .app:
                let plugin = _plugin?.manifest.name ?? ""
                redirectURI = "\(_launch?.appScheme ?? "tinycast")://oauth?plugin=\(plugin)"
            case .custom(let uri): redirectURI = uri
            }
            var items: [(String, String)] = [
                ("response_type", "code"), ("client_id", clientID), ("redirect_uri", redirectURI),
                ("scope", scope), ("state", state), ("code_challenge", challenge),
                ("code_challenge_method", "S256")
            ]
            for (key, value) in extraParameters.sorted(by: { $0.key < $1.key }) {
                items.removeAll { $0.0 == key }
                items.append((key, value))
            }
            let query = items.map { _formEncode($0.0) + "=" + _formEncode($0.1) }.joined(separator: "&")
            let url = endpoint + (endpoint.contains("?") ? "&" : "?") + query
            return AuthorizationRequest(
                url: url, codeVerifier: verifier, codeChallenge: challenge, state: state, redirectURI: redirectURI)
        }

        /// Opens the sign-in and returns the authorization code once the user comes back. Not in a
        /// background run: nobody is there to sign in.
        public func authorize(_ request: AuthorizationRequest) async throws -> String {
            let scheme = String(request.redirectURI.prefix { $0 != ":" })
            let redirect = try await _call("oauth", "authorize", [.string(request.url), .string(scheme)]).text ?? ""
            let items = _queryItems(redirect)
            func value(_ name: String) -> String? { items.first { $0.0 == name }?.1 }
            if let error = value("error") { throw OAuthError.provider(value("error_description") ?? error) }
            guard items.filter({ $0.0 == "state" }).map(\.1) == [request.state] else {
                throw OAuthError.mismatchedState(providerName)
            }
            guard let code = value("code"), !code.isEmpty else { throw OAuthError.noCode(providerName) }
            return code
        }

        /// Kept in the shape Raycast's `setTokens` keeps, under the plugin's own storage.
        public func setTokens(
            accessToken: String, refreshToken: String? = nil, idToken: String? = nil,
            expiresIn: Double? = nil, scope: String? = nil
        ) async throws {
            var tokens: [String: PluginValue] = [
                "accessToken": .string(accessToken), "updatedAt": .string(_iso8601(Date().timeIntervalSince1970))
            ]
            tokens["refreshToken"] = refreshToken.map(PluginValue.string)
            tokens["idToken"] = idToken.map(PluginValue.string)
            tokens["expiresIn"] = expiresIn.map(PluginValue.number)
            tokens["scope"] = scope.map(PluginValue.string)
            _ = try await _call("oauth", "setTokens", [.string(providerID), .string(PluginValue.object(tokens).json)])
        }

        public func getTokens() async throws -> TokenSet? {
            guard let stored = try await _call("oauth", "getTokens", [.string(providerID)]).text, !stored.isEmpty
            else { return nil }
            let fields = PluginValue(json: stored)
            guard let accessToken = fields["accessToken"]?.text else { return nil }
            let updatedAt = fields["updatedAt"]?.text.flatMap(_parseISO8601) ?? Date().timeIntervalSince1970
            return TokenSet(
                accessToken: accessToken, refreshToken: fields["refreshToken"]?.text,
                idToken: fields["idToken"]?.text, expiresIn: fields["expiresIn"]?.numberValue,
                scope: fields["scope"]?.text, updatedAt: Date(timeIntervalSince1970: updatedAt))
        }

        public func removeTokens() async throws {
            _ = try await _call("oauth", "setTokens", [.string(providerID), .null])
        }
    }
}

// MARK: - The pieces PKCE needs

func _randomURLSafe(_ count: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    return _base64URL((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
}

func _base64URL(_ bytes: [UInt8]) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    var output = ""
    var index = 0
    while index < bytes.count {
        let chunk = Array(bytes[index..<min(index + 3, bytes.count)])
        let value = chunk.enumerated().reduce(0) { $0 | UInt32($1.element) << (16 - 8 * UInt32($1.offset)) }
        for position in 0..<(chunk.count + 1) { output.append(alphabet[Int(value >> (18 - 6 * UInt32(position)) & 63)]) }
        index += 3
    }
    return output
}

/// Form encoding, as `URLSearchParams` writes and reads it: a space is `+`.
func _formEncode(_ text: String) -> String {
    var output = ""
    for byte in text.utf8 {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"),
            UInt8(ascii: "~"):
            output.unicodeScalars.append(Unicode.Scalar(byte))
        case UInt8(ascii: " "): output += "+"
        default:
            let hex = String(byte, radix: 16, uppercase: true)
            output += "%" + (hex.count == 1 ? "0" + hex : hex)
        }
    }
    return output
}

func _queryItems(_ url: String) -> [(String, String)] {
    guard let start = url.firstIndex(of: "?") else { return [] }
    let query = url[url.index(after: start)...].prefix { $0 != "#" }
    return query.split(separator: "&").map { pair in
        let parts = pair.split(separator: "=", maxSplits: 1).map { _formDecode(String($0)) }
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }
}

func _formDecode(_ text: String) -> String {
    var bytes: [UInt8] = []
    var iterator = Array(text.utf8).makeIterator()
    while let byte = iterator.next() {
        if byte == UInt8(ascii: "+") {
            bytes.append(UInt8(ascii: " "))
        } else if byte == UInt8(ascii: "%"), let high = iterator.next(), let low = iterator.next(),
            let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16)
        {
            bytes.append(value)
        } else {
            bytes.append(byte)
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// FIPS 180-4.
func _sha256(_ message: [UInt8]) -> [UInt8] {
    let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]
    var hash: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    var padded = message + [0x80]
    while padded.count % 64 != 56 { padded.append(0) }
    let bits = UInt64(message.count) * 8
    for shift in stride(from: 56, through: 0, by: -8) { padded.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
    func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 { value >> count | value << (32 - count) }
    for chunk in stride(from: 0, to: padded.count, by: 64) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            w[i] = (0..<4).reduce(0) { $0 << 8 | UInt32(padded[chunk + i * 4 + $1]) }
        }
        for i in 16..<64 {
            let s0 = rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var (a, b, c, d, e, f, g, h) = (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7])
        for i in 0..<64 {
            let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
            let t1 = h &+ s1 &+ ((e & f) ^ (~e & g)) &+ k[i] &+ w[i]
            let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
            let t2 = s0 &+ ((a & b) ^ (a & c) ^ (b & c))
            (h, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
        }
        for (index, value) in [a, b, c, d, e, f, g, h].enumerated() { hash[index] = hash[index] &+ value }
    }
    return hash.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * UInt32($0))) } }
}
