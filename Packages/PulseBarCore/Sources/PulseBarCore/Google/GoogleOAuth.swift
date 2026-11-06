import CryptoKit
import Foundation

/// OAuth 2.0 authorization code + PKCE for installed apps, per
/// developers.google.com/identity/protocols/oauth2/native-app:
/// loopback redirect (127.0.0.1, random port), S256 challenge, system browser.
public struct GoogleOAuthConfig: Sendable, Equatable {
    public static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    public var clientID: String
    /// Desktop-app client secrets are not confidential (Google says so); still kept in the Keychain.
    public var clientSecret: String?

    public init(clientID: String, clientSecret: String?) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// 64 random URL-safe characters (RFC 7636 allows 43–128).
    public static func random() -> PKCE {
        PKCE(verifier: randomURLSafe(bytes: 48))
    }

    public static func randomURLSafe(bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64url(data)
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct OAuthTokens: Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date
    public var refreshToken: String?
}

public enum GoogleAuthError: Error, Equatable, Sendable {
    /// Refresh token expired or revoked (e.g. the 7-day limit in Testing mode). User must reconnect.
    case reauthRequired
    case stateMismatch
    case userDenied(String)
    case missingCode
    case badResponse(Int, String)
    case notConfigured
}

extension GoogleOAuthConfig {
    public func authorizationURL(redirectURI: String, pkce: PKCE, state: String,
                                 scopes: [String] = GoogleDataType.scopes) -> URL {
        var c = URLComponents(url: Self.authEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),   // ask for a refresh token
            .init(name: "prompt", value: "consent"),        // always re-issue it on reconnect
        ]
        return c.url!
    }

    func tokenRequest(_ params: [String: String]) -> URLRequest {
        var all = params
        all["client_id"] = clientID
        if let clientSecret, !clientSecret.isEmpty { all["client_secret"] = clientSecret }
        var req = URLRequest(url: Self.tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(formEncode(all).utf8)
        return req
    }

    public func exchangeRequest(code: String, redirectURI: String, verifier: String) -> URLRequest {
        tokenRequest(["code": code, "redirect_uri": redirectURI,
                      "grant_type": "authorization_code", "code_verifier": verifier])
    }

    public func refreshRequest(refreshToken: String) -> URLRequest {
        tokenRequest(["refresh_token": refreshToken, "grant_type": "refresh_token"])
    }

    public static func revokeRequest(token: String) -> URLRequest {
        var req = URLRequest(url: revokeEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(formEncode(["token": token]).utf8)
        return req
    }

    /// Parses a token endpoint response. `invalid_grant` means the refresh
    /// token is dead → the user must reconnect.
    public static func parseTokenResponse(_ data: Data, status: Int, now: Date = Date()) throws -> OAuthTokens {
        struct Body: Decodable {
            let access_token: String?
            let expires_in: Int?
            let refresh_token: String?
            let error: String?
            let error_description: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        if body?.error == "invalid_grant" { throw GoogleAuthError.reauthRequired }
        guard (200..<300).contains(status), let access = body?.access_token else {
            throw GoogleAuthError.badResponse(status, body?.error ?? "unknown")
        }
        return OAuthTokens(accessToken: access,
                           expiresAt: now.addingTimeInterval(TimeInterval(body?.expires_in ?? 3600) - 60),
                           refreshToken: body?.refresh_token)
    }

    /// Validates the loopback callback: state must match, and either a code or an error is present.
    public static func code(fromCallback url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard value("state") == expectedState else { throw GoogleAuthError.stateMismatch }
        if let error = value("error") { throw GoogleAuthError.userDenied(error) }
        guard let code = value("code"), !code.isEmpty else { throw GoogleAuthError.missingCode }
        return code
    }
}

func formEncode(_ params: [String: String]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return params.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
        .joined(separator: "&")
}
