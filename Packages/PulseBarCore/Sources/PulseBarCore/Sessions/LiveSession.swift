import Foundation
import GRDB

public enum SessionKind: String, Codable, Sendable, CaseIterable {
    case desk
    case workout
}

/// A recorded stretch of live heart rate (spec F2.4).
public struct LiveSession: Codable, Sendable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "live_sessions"

    public var id: Int64?
    public var start: Date
    public var end: Date?
    public var kind: SessionKind
    public var deviceName: String?
    public var avgHR: Double?
    public var maxHR: Int?
    public var liveRMSSDms: Double?

    enum CodingKeys: String, CodingKey {
        case id, start, end, kind
        case deviceName = "device_name"
        case avgHR = "avg_hr"
        case maxHR = "max_hr"
        case liveRMSSDms = "live_rmssd_ms"
    }

    public init(start: Date, kind: SessionKind, deviceName: String?) {
        self.start = start
        self.kind = kind
        self.deviceName = deviceName
    }

    public var duration: TimeInterval? { end.map { $0.timeIntervalSince(start) } }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension AppDatabase {
    /// Recomputes avg/max HR and live RMSSD from stored samples and closes the session.
    func finalizeSession(_ id: Int64, end: Date?) throws {
        try writer.write { db in
            let stats = try Row.fetchOne(db, sql: """
                SELECT AVG(bpm) AS avg, MAX(bpm) AS max, MAX(ts) AS last
                FROM live_samples WHERE session_id = ?
                """, arguments: [id])
            let rr = try Double.fetchAll(db, sql: "SELECT rr_ms FROM live_rr WHERE session_id = ? ORDER BY ts, rowid",
                                         arguments: [id])
            let lastSample: Date? = stats?["last"]
            let start = try Date.fetchOne(db, sql: "SELECT start FROM live_sessions WHERE id = ?", arguments: [id])
            try db.execute(sql: """
                UPDATE live_sessions SET end = ?, avg_hr = ?, max_hr = ?, live_rmssd_ms = ? WHERE id = ?
                """, arguments: [end ?? lastSample ?? start, stats?["avg"] as Double?, stats?["max"] as Int?,
                                 LiveHRV.rmssd(rr), id])
        }
    }

    /// Closes sessions left open by a crash or force-quit (no data loss: samples
    /// were already flushed; the end becomes the last sample time).
    public func recoverOpenSessions() throws {
        let open = try writer.read { try Int64.fetchAll($0, sql: "SELECT id FROM live_sessions WHERE end IS NULL") }
        for id in open { try finalizeSession(id, end: nil) }
    }

    public func sessions(from: Date, to: Date) throws -> [LiveSession] {
        try writer.read { db in
            try LiveSession.filter(Column("start") >= from && Column("start") < to)
                .order(Column("start")).fetchAll(db)
        }
    }
}
