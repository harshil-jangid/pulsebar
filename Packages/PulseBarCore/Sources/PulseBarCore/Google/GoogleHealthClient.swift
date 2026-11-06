import Foundation
import os

/// HTTP transport, abstracted so tests can replay recorded responses.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Talks to https://health.googleapis.com/v4 with the user's tokens.
/// - refreshes the access token when it expires or a call returns 401
/// - retries 429 / 5xx with exponential backoff and jitter (F3.8), honoring Retry-After
/// - follows `nextPageToken` until done
public actor GoogleHealthClient {
    public static let baseURL = URL(string: "https://health.googleapis.com/v4/users/me/dataTypes/")!

    private let config: GoogleOAuthConfig
    private let secrets: SecretStore
    private let transport: HTTPTransport
    private let sleep: @Sendable (Double) async throws -> Void
    private var tokens: OAuthTokens?
    private let log = Logger(subsystem: "io.github.pulsebar", category: "Google")
    let maxAttempts = 5

    public init(config: GoogleOAuthConfig, secrets: SecretStore, transport: HTTPTransport = URLSessionTransport(),
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.config = config
        self.secrets = secrets
        self.transport = transport
        self.sleep = sleep
    }

    /// All reconciled data points for a type over [from, to) local dates (YYYY-MM-DD).
    func reconcile(_ type: GoogleDataType, from: String, to: String) async throws -> [GReconciledDataPoint] {
        var all: [GReconciledDataPoint] = []
        var pageToken: String?
        repeat {
            var c = URLComponents(url: Self.baseURL.appending(path: "\(type.rawValue)/dataPoints:reconcile"),
                                  resolvingAgainstBaseURL: false)!
            c.queryItems = [.init(name: "filter", value: type.filter(from: from, to: to)),
                            .init(name: "pageSize", value: type == .steps ? "10000" : "1000")]
            if let pageToken { c.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
            let data = try await authorizedGET(c.url!)
            let page = try JSONDecoder().decode(GReconcileResponse.self, from: data)
            all += page.dataPoints ?? []
            pageToken = page.nextPageToken?.isEmpty == false ? page.nextPageToken : nil
        } while pageToken != nil
        return all
    }

    private func authorizedGET(_ url: URL) async throws -> Data {
        var refreshedAfter401 = false
        var attempt = 0
        var backoff = ReconnectBackoff(base: 1, cap: 32)
        while true {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await transport.send(req)
            switch response.statusCode {
            case 200..<300:
                return data
            case 401 where !refreshedAfter401:
                refreshedAfter401 = true
                tokens = nil // force refresh
            case 429, 500...599:
                attempt += 1
                guard attempt < maxAttempts else { throw GoogleAuthError.badResponse(response.statusCode, "gave up after retries") }
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let delay = retryAfter ?? backoff.nextDelay()
                log.notice("HTTP \(response.statusCode); retrying in \(delay, format: .fixed(precision: 1))s")
                try await sleep(delay)
            case 401, 403:
                // 403 can mean a scope was unchecked on the consent screen.
                throw response.statusCode == 401 ? GoogleAuthError.reauthRequired
                    : GoogleAuthError.badResponse(403, Self.errorMessage(data))
            default:
                throw GoogleAuthError.badResponse(response.statusCode, Self.errorMessage(data))
            }
        }
    }

    private func accessToken() async throws -> String {
        if let tokens, tokens.expiresAt > Date() { return tokens.accessToken }
        guard let refresh = secrets.get(SecretKey.refreshToken) else { throw GoogleAuthError.reauthRequired }
        let (data, response) = try await transport.send(config.refreshRequest(refreshToken: refresh))
        let new = try GoogleOAuthConfig.parseTokenResponse(data, status: response.statusCode)
        if let rotated = new.refreshToken { try secrets.set(SecretKey.refreshToken, rotated) }
        tokens = new
        return new.accessToken
    }

    /// Only the API's error message, never the body (which could contain health data).
    static func errorMessage(_ data: Data) -> String {
        struct E: Decodable { struct Inner: Decodable { let message: String? }; let error: Inner? }
        return (try? JSONDecoder().decode(E.self, from: data))?.error?.message ?? "request failed"
    }
}
