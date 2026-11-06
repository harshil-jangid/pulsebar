import Foundation
import GRDB
import Observation
import os

public enum GoogleSyncStatus: Sendable, Equatable {
    case notConnected
    case idle
    case syncing(String)
    /// Refresh token expired or was revoked: show "Reconnect Google" (F3.4).
    case reauthRequired
    case error(String)
}

/// Writes reconciled Google data into `daily_metrics` / `workouts`.
/// Pure database logic (no network), so it is fully unit-tested.
/// Every write is an upsert keyed by date or workout id, so re-running a sync
/// never creates duplicates (F3.5).
struct GoogleDataWriter {
    let db: AppDatabase
    var calendar: Calendar = .current

    func apply(_ type: GoogleDataType, _ points: [GReconciledDataPoint], now: Date = Date()) throws {
        try db.writer.write { db in
            switch type {
            case .restingHeartRate:
                for p in points.compactMap(\.dailyRestingHeartRate) {
                    try upsert(db, p.date.iso, ["resting_hr": Double(p.beatsPerMinute.value)], now)
                }
            case .heartRateVariability:
                for p in points.compactMap(\.dailyHeartRateVariability) {
                    guard let ms = p.averageHeartRateVariabilityMilliseconds else { continue }
                    try upsert(db, p.date.iso, ["hrv_rmssd_ms": ms], now)
                }
            case .oxygenSaturation:
                for p in points.compactMap(\.dailyOxygenSaturation) {
                    try upsert(db, p.date.iso, ["spo2_avg": p.averagePercentage], now)
                }
            case .respiratoryRate:
                for p in points.compactMap(\.dailyRespiratoryRate) {
                    try upsert(db, p.date.iso, ["resp_rate": p.breathsPerMinute], now)
                }
            case .vo2Max:
                for p in points.compactMap(\.dailyVo2Max) {
                    try upsert(db, p.date.iso, ["vo2max": p.vo2Max], now)
                }
            case .sleep:
                try applySleep(db, points.compactMap(\.sleep), now)
            case .steps:
                var byDay: [String: Int] = [:]
                for s in points.compactMap(\.steps) {
                    guard let day = localDay(s.interval.civilStartTime, s.interval.startTime) else { continue }
                    byDay[day, default: 0] += s.count.value
                }
                for (day, total) in byDay { try upsert(db, day, ["steps": total], now) }
            case .exercise:
                for p in points {
                    guard let e = p.exercise, let start = GoogleTime.parse(e.interval.startTime) else { continue }
                    let id = p.dataPointName ?? "\(e.interval.startTime)|\(e.exerciseType ?? "")"
                    try db.execute(sql: """
                        INSERT INTO workouts (id, start, end, type, avg_hr, max_hr, source)
                        VALUES (?, ?, ?, ?, ?, NULL, 'google')
                        ON CONFLICT(id) DO UPDATE SET start = excluded.start, end = excluded.end,
                            type = excluded.type, avg_hr = excluded.avg_hr
                        """, arguments: [id, start, GoogleTime.parse(e.interval.endTime),
                                         e.displayName ?? e.exerciseType,
                                         e.metricsSummary?.averageHeartRateBeatsPerMinute.map { Double($0.value) }])
                }
            }
        }
    }

    /// One sleep per wake-up date: the main sleep if flagged, otherwise the longest. Naps ignored.
    private func applySleep(_ db: Database, _ sleeps: [GSleep], _ now: Date) throws {
        var best: [String: GSleep] = [:]
        for s in sleeps where s.metadata?.nap != true {
            guard let day = localDay(s.interval.civilEndTime, s.interval.endTime) else { continue }
            if let current = best[day] {
                let currentMain = current.metadata?.mainSleep == true
                let newMain = s.metadata?.mainSleep == true
                if currentMain && !newMain { continue }
                if newMain == currentMain && minutesAsleep(s) <= minutesAsleep(current) { continue }
            }
            best[day] = s
        }
        for (day, s) in best {
            func stage(_ t: String) -> Int? { s.summary?.stagesSummary?.first { $0.type == t }?.minutes?.value }
            var values: [String: (any DatabaseValueConvertible)?] = [
                "sleep_minutes": minutesAsleep(s),
                "sleep_start": GoogleTime.parse(s.interval.startTime),
                "sleep_end": GoogleTime.parse(s.interval.endTime),
            ]
            // Only write stage columns Google actually reported (classic sleep has none).
            let awake: Int? = stage("AWAKE") ?? s.summary?.minutesAwake?.value
            for (column, minutes) in [("deep_min", stage("DEEP")), ("rem_min", stage("REM")),
                                      ("light_min", stage("LIGHT")), ("awake_min", awake)] {
                if let minutes { values[column] = minutes }
            }
            try upsert(db, day, values, now)
        }
    }

    private func minutesAsleep(_ s: GSleep) -> Int {
        if let m = s.summary?.minutesAsleep?.value { return m }
        guard let a = GoogleTime.parse(s.interval.startTime), let b = GoogleTime.parse(s.interval.endTime) else { return 0 }
        return Int(b.timeIntervalSince(a) / 60)
    }

    /// Prefer the API's civil (user-local) date; fall back to our calendar.
    private func localDay(_ civil: GCivilDateTime?, _ timestamp: String) -> String? {
        if let civil { return civil.date.iso }
        guard let d = GoogleTime.parse(timestamp) else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func upsert(_ db: Database, _ day: String, _ values: [String: (any DatabaseValueConvertible)?], _ now: Date) throws {
        let cols = values.keys.sorted()
        let sql = """
            INSERT INTO daily_metrics (date, \(cols.joined(separator: ", ")), source, updated_at)
            VALUES (?, \(cols.map { _ in "?" }.joined(separator: ", ")), 'google', ?)
            ON CONFLICT(date) DO UPDATE SET \(cols.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")),
                source = 'google', updated_at = excluded.updated_at
            """
        var args: [(any DatabaseValueConvertible)?] = [day]
        args += cols.map { values[$0]! }
        args.append(now)
        try db.execute(sql: sql, arguments: StatementArguments(args))
    }
}

/// Connect / disconnect / sync orchestration for the app (F3.3–F3.8).
@MainActor
@Observable
public final class GoogleSync {
    public static let backfillDays = 90
    /// Re-fetch this many recent days each run: Google may finalize sleep/HRV late.
    public static let overlapDays = 3

    public private(set) var status: GoogleSyncStatus = .notConnected
    public private(set) var lastSuccess: Date?

    @ObservationIgnored private let db: AppDatabase
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let secrets: SecretStore
    @ObservationIgnored private let transport: HTTPTransport
    @ObservationIgnored private let retrySleep: @Sendable (Double) async throws -> Void
    @ObservationIgnored private let log = Logger(subsystem: "io.github.pulsebar", category: "GoogleSync")
    @ObservationIgnored private var client: GoogleHealthClient?
    @ObservationIgnored var calendar: Calendar = .current

    public init(db: AppDatabase, settings: SettingsStore, secrets: SecretStore,
                transport: HTTPTransport = URLSessionTransport(),
                retrySleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.retrySleep = retrySleep
        self.db = db
        self.settings = settings
        self.secrets = secrets
        self.transport = transport
        lastSuccess = try? db.writer.read { try Date.fetchOne($0, sql: "SELECT MAX(last_success) FROM sync_state") }
        status = isConnected ? .idle : .notConnected
    }

    public var isConnected: Bool {
        settings.value.googleClientID != nil && secrets.get(SecretKey.refreshToken) != nil
    }

    private var config: GoogleOAuthConfig? {
        settings.value.googleClientID.map {
            GoogleOAuthConfig(clientID: $0, clientSecret: secrets.get(SecretKey.clientSecret))
        }
    }

    /// Full browser sign-in. `openURL` opens the system browser (never an embedded web view).
    public func connect(clientID: String, clientSecret: String?, openURL: @escaping (URL) -> Void) async throws {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.update { $0.googleClientID = id; $0.useGoogleHealth = true }
        try secrets.set(SecretKey.clientSecret, secret?.isEmpty == false ? secret : nil)
        let config = GoogleOAuthConfig(clientID: id, clientSecret: secret)

        let receiver = try LoopbackReceiver()
        let redirect = try await receiver.start()
        let pkce = PKCE.random()
        let state = PKCE.randomURLSafe(bytes: 16)
        openURL(config.authorizationURL(redirectURI: redirect, pkce: pkce, state: state))
        let callback = try await receiver.waitForCallback()
        let code = try GoogleOAuthConfig.code(fromCallback: callback, expectedState: state)

        let (data, response) = try await transport.send(
            config.exchangeRequest(code: code, redirectURI: redirect, verifier: pkce.verifier))
        let tokens = try GoogleOAuthConfig.parseTokenResponse(data, status: response.statusCode)
        guard let refresh = tokens.refreshToken else {
            throw GoogleAuthError.badResponse(response.statusCode, "Google didn't return a refresh token")
        }
        try secrets.set(SecretKey.refreshToken, refresh)
        client = nil
        status = .idle
        await sync()
    }

    /// Revokes the token at Google and deletes it locally (F9.2). Synced data stays
    /// until the user deletes it from Settings → Data.
    public func disconnect() async {
        if let refresh = secrets.get(SecretKey.refreshToken) {
            _ = try? await transport.send(GoogleOAuthConfig.revokeRequest(token: refresh))
        }
        try? secrets.set(SecretKey.refreshToken, nil)
        client = nil
        status = .notConnected
    }

    /// Backfill on first run, then incremental with a small overlap. Safe to call any time.
    public func sync(now: Date = Date()) async {
        guard isConnected, let config else { status = .notConnected; return }
        if case .syncing = status { return }
        let client = self.client ?? GoogleHealthClient(config: config, secrets: secrets, transport: transport, sleep: retrySleep)
        self.client = client
        let writer = GoogleDataWriter(db: db, calendar: calendar)
        let today = Self.dayString(now, calendar)
        let tomorrow = Self.dayString(calendar.date(byAdding: .day, value: 1, to: now)!, calendar)

        for type in GoogleDataType.allCases {
            status = .syncing(type.rawValue)
            let from = startDay(for: type, now: now)
            do {
                let points = try await client.reconcile(type, from: from, to: tomorrow)
                try writer.apply(type, points, now: now)
                try saveState(type, cursor: today, error: nil, success: now)
            } catch GoogleAuthError.reauthRequired {
                status = .reauthRequired
                return
            } catch {
                log.error("Sync \(type.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                try? saveState(type, cursor: nil, error: Self.describe(error), success: nil)
                status = .error(Self.describe(error))
                return
            }
        }
        lastSuccess = now
        status = .idle
    }

    private func startDay(for type: GoogleDataType, now: Date) -> String {
        let cursor = try? db.writer.read {
            try String.fetchOne($0, sql: "SELECT cursor FROM sync_state WHERE data_type = ?", arguments: [type.rawValue])
        }
        if let cursor, let date = Self.parseDay(cursor, calendar) {
            return Self.dayString(calendar.date(byAdding: .day, value: -Self.overlapDays, to: date)!, calendar)
        }
        return Self.dayString(calendar.date(byAdding: .day, value: -Self.backfillDays, to: now)!, calendar)
    }

    private func saveState(_ type: GoogleDataType, cursor: String?, error: String?, success: Date?) throws {
        try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO sync_state (data_type, last_success, cursor, last_error) VALUES (?, ?, ?, ?)
                ON CONFLICT(data_type) DO UPDATE SET
                    last_success = COALESCE(excluded.last_success, last_success),
                    cursor = COALESCE(excluded.cursor, cursor),
                    last_error = excluded.last_error
                """, arguments: [type.rawValue, success, cursor, error])
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case GoogleAuthError.badResponse(403, let m): "Permission denied by Google (\(m)). Check that all three scopes were allowed."
        case GoogleAuthError.badResponse(let code, let m): "Google returned an error (\(code)): \(m)"
        case let e as URLError where e.code == .notConnectedToInternet: "You're offline. PulseBar will sync when you're back online."
        default: "Sync failed. PulseBar will try again later."
        }
    }

    public static func dayString(_ date: Date, _ calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func parseDay(_ s: String, _ calendar: Calendar = .current) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}
