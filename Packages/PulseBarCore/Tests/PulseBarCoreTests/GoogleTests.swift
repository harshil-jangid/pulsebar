import Foundation
import GRDB
import Testing
@testable import PulseBarCore

/// Replays canned responses by URL substring and records every request.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Reply { let status: Int; let body: String; var headers: [String: String] = [:] }
    private let lock = NSLock()
    private var routes: [(match: String, replies: [Reply])] = []
    private(set) var requests: [URLRequest] = []

    func on(_ match: String, _ replies: Reply...) { lock.withLock { routes.append((match, replies)) } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try lock.withLock {
            requests.append(request)
            let url = request.url!.absoluteString
            guard let i = routes.firstIndex(where: { url.contains($0.match) && !$0.replies.isEmpty }) else {
                throw URLError(.unsupportedURL)
            }
            let r = routes[i].replies.count > 1 ? routes[i].replies.removeFirst() : routes[i].replies[0]
            let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: nil, headerFields: r.headers)!
            return (Data(r.body.utf8), http)
        }
    }

    func count(_ match: String) -> Int { lock.withLock { requests.filter { $0.url!.absoluteString.contains(match) }.count } }
    func filters(_ match: String) -> [String] {
        lock.withLock {
            requests.filter { $0.url!.absoluteString.contains(match) }.compactMap {
                URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "filter" }?.value
            }
        }
    }
}

enum Fixture {
    static let token = #"{"access_token":"ya29.test","expires_in":3599,"token_type":"Bearer"}"#
    static let empty = #"{"dataPoints":[]}"#
    static let restingHR = #"""
    {"dataPoints":[
      {"dailyRestingHeartRate":{"beatsPerMinute":"58","date":{"year":2026,"month":11,"day":4},
        "dailyRestingHeartRateMetadata":{"calculationMethod":"WITH_SLEEP"}}},
      {"dailyRestingHeartRate":{"beatsPerMinute":"60","date":{"year":2026,"month":11,"day":5}}}]}
    """#
    static let hrv = #"""
    {"dataPoints":[{"dailyHeartRateVariability":{"averageHeartRateVariabilityMilliseconds":42.5,
      "deepSleepRootMeanSquareOfSuccessiveDifferencesMilliseconds":48.1,"date":{"year":2026,"month":11,"day":5}}}]}
    """#
    // Main sleep + a nap ending the same day: the nap must be ignored.
    static let sleep = #"""
    {"dataPoints":[
      {"sleep":{"interval":{"startTime":"2026-11-04T17:30:00Z","endTime":"2026-11-05T01:00:00Z",
         "startUtcOffset":"19800s","endUtcOffset":"19800s",
         "civilEndTime":{"date":{"year":2026,"month":11,"day":5},"time":{"hours":6,"minutes":30}}},
       "type":"STAGES","metadata":{"mainSleep":true,"nap":false},
       "summary":{"minutesAsleep":"412","minutesAwake":"38","stagesSummary":[
          {"type":"DEEP","minutes":"71","count":"4"},{"type":"REM","minutes":"95","count":"5"},
          {"type":"LIGHT","minutes":"246","count":"20"},{"type":"AWAKE","minutes":"38","count":"12"}]}}},
      {"sleep":{"interval":{"startTime":"2026-11-05T09:00:00Z","endTime":"2026-11-05T09:40:00Z",
         "civilEndTime":{"date":{"year":2026,"month":11,"day":5}}},
       "metadata":{"mainSleep":false,"nap":true},"summary":{"minutesAsleep":"35"}}}]}
    """#
    static func steps(page: Int) -> String {
        page == 1 ? #"""
        {"dataPoints":[
          {"steps":{"count":"1200","interval":{"startTime":"2026-11-05T03:00:00Z","endTime":"2026-11-05T03:01:00Z",
             "civilStartTime":{"date":{"year":2026,"month":11,"day":5}}}}},
          {"steps":{"count":"800","interval":{"startTime":"2026-11-05T04:00:00Z","endTime":"2026-11-05T04:01:00Z",
             "civilStartTime":{"date":{"year":2026,"month":11,"day":5}}}}}],
         "nextPageToken":"p2"}
        """# : #"""
        {"dataPoints":[
          {"steps":{"count":"5000","interval":{"startTime":"2026-11-04T05:00:00Z","endTime":"2026-11-04T05:01:00Z",
             "civilStartTime":{"date":{"year":2026,"month":11,"day":4}}}}}]}
        """#
    }
    static let exercise = #"""
    {"dataPoints":[{"dataPointName":"users/me/dataTypes/exercise/dataPoints/abc123",
      "exercise":{"interval":{"startTime":"2026-11-05T12:00:00Z","endTime":"2026-11-05T12:45:00Z"},
        "exerciseType":"RUNNING","displayName":"Run","metricsSummary":{"averageHeartRateBeatsPerMinute":"148"}}}]}
    """#
    static let spo2 = #"{"dataPoints":[{"dailyOxygenSaturation":{"averagePercentage":96.4,"lowerBoundPercentage":94,"upperBoundPercentage":98,"date":{"year":2026,"month":11,"day":5}}}]}"#
    static let resp = #"{"dataPoints":[{"dailyRespiratoryRate":{"breathsPerMinute":14.2,"date":{"year":2026,"month":11,"day":5}}}]}"#
    static let vo2 = #"{"dataPoints":[{"dailyVo2Max":{"vo2Max":44.1,"estimated":true,"date":{"year":2026,"month":11,"day":5}}}]}"#
}

@Suite("Google OAuth")
struct GoogleOAuthTests {
    @Test("PKCE S256 matches the RFC 7636 Appendix B example")
    func pkceVector() {
        let p = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(p.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCE.random().verifier.count >= 43)
    }

    @Test("authorization URL: PKCE, offline access, only the three read-only scopes")
    func authURL() throws {
        let cfg = GoogleOAuthConfig(clientID: "cid.apps.googleusercontent.com", clientSecret: nil)
        let url = cfg.authorizationURL(redirectURI: "http://127.0.0.1:5555/", pkce: PKCE(verifier: "x".padding(toLength: 43, withPad: "x", startingAt: 0)), state: "st")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["access_type"] == "offline")
        #expect(items["redirect_uri"] == "http://127.0.0.1:5555/")
        let scopes = try #require(items["scope"]).split(separator: " ")
        #expect(scopes.count == 3)
        #expect(scopes.allSatisfy { $0.hasSuffix(".readonly") })
    }

    @Test("callback validation: state mismatch, user denial, success")
    func callback() throws {
        let ok = URL(string: "http://127.0.0.1:5555/?state=abc&code=4/xyz")!
        #expect(try GoogleOAuthConfig.code(fromCallback: ok, expectedState: "abc") == "4/xyz")
        #expect(throws: GoogleAuthError.stateMismatch) {
            try GoogleOAuthConfig.code(fromCallback: ok, expectedState: "other")
        }
        let denied = URL(string: "http://127.0.0.1:5555/?state=abc&error=access_denied")!
        #expect(throws: GoogleAuthError.userDenied("access_denied")) {
            try GoogleOAuthConfig.code(fromCallback: denied, expectedState: "abc")
        }
    }

    @Test("invalid_grant → reauthRequired")
    func invalidGrant() {
        #expect(throws: GoogleAuthError.reauthRequired) {
            try GoogleOAuthConfig.parseTokenResponse(Data(#"{"error":"invalid_grant"}"#.utf8), status: 400)
        }
    }

    @Test("token exchange sends the PKCE verifier and omits an empty secret")
    func exchange() throws {
        let req = GoogleOAuthConfig(clientID: "cid", clientSecret: "").exchangeRequest(
            code: "c", redirectURI: "http://127.0.0.1:1/", verifier: "ver")
        let body = String(decoding: try #require(req.httpBody), as: UTF8.self)
        #expect(body.contains("code_verifier=ver"))
        #expect(body.contains("grant_type=authorization_code"))
        #expect(!body.contains("client_secret"))
    }
}

@MainActor
@Suite("Google sync")
struct GoogleSyncTests {
    let db = try! AppDatabase.inMemory()
    let secrets = MemorySecretStore()
    let transport = MockTransport()
    let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 9))!

    func makeSync() -> GoogleSync {
        let settings = SettingsStore(db: db)
        settings.update { $0.googleClientID = "cid" }
        try! secrets.set(SecretKey.refreshToken, "1//refresh")
        let sync = GoogleSync(db: db, settings: settings, secrets: secrets, transport: transport,
                              retrySleep: { _ in })
        sync.calendar = utc
        return sync
    }

    func routeAll() {
        transport.on("oauth2.googleapis.com/token", .init(status: 200, body: Fixture.token))
        transport.on("daily-resting-heart-rate", .init(status: 200, body: Fixture.restingHR))
        transport.on("daily-heart-rate-variability", .init(status: 200, body: Fixture.hrv))
        transport.on("/sleep/", .init(status: 200, body: Fixture.sleep))
        transport.on("pageToken=p2", .init(status: 200, body: Fixture.steps(page: 2)))
        transport.on("/steps/", .init(status: 200, body: Fixture.steps(page: 1)))
        transport.on("/exercise/", .init(status: 200, body: Fixture.exercise))
        transport.on("daily-oxygen-saturation", .init(status: 200, body: Fixture.spo2))
        transport.on("daily-respiratory-rate", .init(status: 200, body: Fixture.resp))
        transport.on("daily-vo2-max", .init(status: 200, body: Fixture.vo2))
    }

    func row(_ day: String) throws -> Row? {
        try db.writer.read { try Row.fetchOne($0, sql: "SELECT * FROM daily_metrics WHERE date = ?", arguments: [day]) }
    }

    @Test("full sync maps every type into daily_metrics and workouts")
    func fullSync() async throws {
        routeAll()
        let sync = makeSync()
        await sync.sync(now: now)
        #expect(sync.status == .idle)

        let d5 = try #require(try row("2026-11-05"))
        #expect(d5["resting_hr"] as Double? == 60)
        #expect(d5["hrv_rmssd_ms"] as Double? == 42.5)
        #expect(d5["sleep_minutes"] as Int? == 412)          // main sleep, nap ignored
        #expect(d5["deep_min"] as Int? == 71)
        #expect(d5["rem_min"] as Int? == 95)
        #expect(d5["steps"] as Int? == 2000)                 // summed across intervals and pages
        #expect(d5["spo2_avg"] as Double? == 96.4)
        #expect(d5["resp_rate"] as Double? == 14.2)
        #expect(d5["vo2max"] as Double? == 44.1)
        #expect(try row("2026-11-04")?["steps"] as Int? == 5000)
        #expect(try row("2026-11-04")?["resting_hr"] as Double? == 58)

        let avgHRs = try await db.writer.read { try Double.fetchAll($0, sql: "SELECT avg_hr FROM workouts") }
        #expect(avgHRs == [148])
        #expect(transport.count("pageToken=p2") == 1)        // followed pagination
    }

    @Test("re-running sync creates no duplicates and doesn't double steps")
    func idempotent() async throws {
        routeAll()
        let sync = makeSync()
        await sync.sync(now: now)
        await sync.sync(now: now)
        let days = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM daily_metrics") }
        let workouts = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM workouts") }
        #expect(days == 2)
        #expect(workouts == 1)
        #expect(try row("2026-11-05")?["steps"] as Int? == 2000)
    }

    @Test("first sync backfills 90 days; next sync overlaps only 3 days")
    func incremental() async throws {
        routeAll()
        let sync = makeSync()
        await sync.sync(now: now)
        await sync.sync(now: now)
        let filters = transport.filters("daily-resting-heart-rate")
        #expect(filters.first == #"daily_resting_heart_rate.date >= "2026-08-08" AND daily_resting_heart_rate.date < "2026-11-07""#)
        #expect(filters.last == #"daily_resting_heart_rate.date >= "2026-11-03" AND daily_resting_heart_rate.date < "2026-11-07""#)
    }

    @Test("429 is retried with backoff, then succeeds")
    func retries() async throws {
        transport.on("daily-resting-heart-rate",
                     .init(status: 429, body: "{}", headers: ["Retry-After": "2"]),
                     .init(status: 503, body: "{}"),
                     .init(status: 200, body: Fixture.restingHR))
        routeAll()
        let sync = makeSync()
        await sync.sync(now: now)
        #expect(sync.status == .idle)
        #expect(transport.count("daily-resting-heart-rate") == 3)
    }

    @Test("401 triggers one token refresh and a retry")
    func refreshOn401() async throws {
        transport.on("daily-resting-heart-rate", .init(status: 401, body: "{}"), .init(status: 200, body: Fixture.restingHR))
        routeAll()
        let sync = makeSync()
        await sync.sync(now: now)
        #expect(sync.status == .idle)
        #expect(transport.count("oauth2.googleapis.com/token") == 2)
    }

    @Test("expired/revoked refresh token → Reconnect state, no crash, data kept")
    func reauth() async throws {
        routeAll()
        let sync = makeSync()
        await sync.sync(now: now)
        let transport2 = MockTransport()
        transport2.on("oauth2.googleapis.com/token", .init(status: 400, body: #"{"error":"invalid_grant"}"#))
        let settings = SettingsStore(db: db)
        let sync2 = GoogleSync(db: db, settings: settings, secrets: secrets, transport: transport2)
        await sync2.sync(now: now)
        #expect(sync2.status == .reauthRequired)
        #expect(try row("2026-11-05")?["resting_hr"] as Double? == 60) // nothing lost
    }

    @Test("disconnect revokes at Google and deletes the local token")
    func disconnect() async throws {
        transport.on("oauth2.googleapis.com/revoke", .init(status: 200, body: "{}"))
        let sync = makeSync()
        await sync.disconnect()
        #expect(transport.count("revoke") == 1)
        #expect(secrets.get(SecretKey.refreshToken) == nil)
        #expect(sync.status == .notConnected)
    }

    @Test("not connected → sync does nothing")
    func notConnected() async {
        let sync = GoogleSync(db: db, settings: SettingsStore(db: db), secrets: secrets, transport: transport)
        await sync.sync(now: now)
        #expect(sync.status == .notConnected)
        #expect(transport.requests.isEmpty)
    }
}

@Suite("LoopbackReceiver")
struct LoopbackReceiverTests {
    @Test("receives the browser redirect on 127.0.0.1 and answers with a page")
    func roundTrip() async throws {
        let receiver = try LoopbackReceiver()
        let redirect = try await receiver.start()
        #expect(redirect.hasPrefix("http://127.0.0.1:"))
        async let callback = receiver.waitForCallback(timeout: .seconds(5))
        let (data, response) = try await URLSession.shared.data(from: URL(string: redirect + "?state=s1&code=c1")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("PulseBar is connected"))
        let url = try await callback
        #expect(try GoogleOAuthConfig.code(fromCallback: url, expectedState: "s1") == "c1")
    }
}
