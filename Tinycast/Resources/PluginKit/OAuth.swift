// Signing in to a service with OAuth 2.0 and PKCE.

import Foundation
import _TinycastHost

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
    public typealias AuthorizationRequest = PluginOAuthRequest

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

    /// Runs the browser sign-in and keeps each provider's tokens in the plugin's storage. The token
    /// exchange is the plugin's: a `URLSession` request with the code and `codeVerifier`, which
    /// needs the `network` permission.
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
            guard let environment = _environment else { throw OAuthError.noSession }
            var redirectURI: String? = nil
            if case .custom(let uri) = redirect { redirectURI = uri }
            return try environment.oauthRequest(
                endpoint: endpoint, clientID: clientID, scope: scope, extraParameters: extraParameters,
                redirectURI: redirectURI)
        }

        /// Opens the sign-in and returns the authorization code once the user comes back. Not in a
        /// background run: nobody is there to sign in.
        public func authorize(_ request: AuthorizationRequest) async throws -> String {
            guard let environment = _environment else { throw OAuthError.noSession }
            return try await environment.oauthAuthorize(request, providerName: providerName)
        }

        public func setTokens(
            accessToken: String, refreshToken: String? = nil, idToken: String? = nil,
            expiresIn: Double? = nil, scope: String? = nil
        ) async throws {
            guard let environment = _environment else { throw OAuthError.noSession }
            try await environment.setOAuthTokens(
                provider: providerID, accessToken: accessToken, refreshToken: refreshToken, idToken: idToken,
                expiresIn: expiresIn, scope: scope)
        }

        public func getTokens() async throws -> TokenSet? {
            guard let environment = _environment,
                let stored = try await environment.oauthTokens(provider: providerID)
            else { return nil }
            return TokenSet(
                accessToken: stored.accessToken, refreshToken: stored.refreshToken, idToken: stored.idToken,
                expiresIn: stored.expiresIn, scope: stored.scope,
                updatedAt: Date(timeIntervalSince1970: stored.updatedAt))
        }

        public func removeTokens() async throws {
            guard let environment = _environment else { throw OAuthError.noSession }
            try await environment.removeOAuthTokens(provider: providerID)
        }
    }

    public enum OAuthError: Error {
        /// Called outside a running command.
        case noSession
    }
}
