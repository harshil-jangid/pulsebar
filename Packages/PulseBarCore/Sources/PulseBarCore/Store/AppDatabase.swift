import Foundation
import GRDB

/// Owns the SQLite database and its versioned migrations.
///
/// The app opens it read-write; `pulsebar-mcp` opens it read-only
/// (`AppDatabase.openReadOnly`), so the connector can never write.
public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// Wraps an existing connection and runs all pending migrations.
    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// In-memory database for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: Self.configuration()))
    }

    /// `~/Library/Application Support/PulseBar/` (spec §4).
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "PulseBar", directoryHint: .isDirectory)
    }

    public static var defaultURL: URL { defaultDirectory.appending(path: "pulsebar.sqlite") }

    /// Opens (creating if needed) the database file. Directory 0700, file 0600,
    /// so other users on the Mac can't read health data.
    public static func openShared(at url: URL = defaultURL) throws -> AppDatabase {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let db = try AppDatabase(DatabaseQueue(path: url.path, configuration: configuration()))
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return db
    }

    /// Read-only connection to an existing database file (used by the MCP server).
    /// Runs no migrations; it only reads what the app has written.
    public static func openReadOnly(at url: URL = defaultURL) throws -> any DatabaseReader {
        var config = configuration()
        config.readonly = true
        return try DatabaseQueue(path: url.path, configuration: config)
    }

    static func configuration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        // App and MCP server may touch the file at the same time; wait briefly instead of failing.
        config.busyMode = .timeout(5)
        return config
    }

    /// Ordered, append-only list of schema changes. Never edit a shipped
    /// migration; add a new one instead.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_settings") { db in
            try db.create(table: "settings") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }

        migrator.registerMigration("v2_live_sessions") { db in
            try db.create(table: "live_sessions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("start", .datetime).notNull().indexed()
                t.column("end", .datetime)
                t.column("kind", .text).notNull()            // desk | workout
                t.column("device_name", .text)
                t.column("avg_hr", .double)
                t.column("max_hr", .integer)
                t.column("live_rmssd_ms", .double)
            }
            try db.create(table: "live_samples") { t in
                t.column("session_id", .integer).notNull()
                    .references("live_sessions", onDelete: .cascade)
                t.column("ts", .datetime).notNull()
                t.column("bpm", .integer).notNull()
            }
            try db.create(index: "live_samples_session_ts", on: "live_samples", columns: ["session_id", "ts"])
            // One packet can carry several RR intervals, so they get their own
            // rows instead of a single nullable column (deviation from SPEC §5.1).
            try db.create(table: "live_rr") { t in
                t.column("session_id", .integer).notNull()
                    .references("live_sessions", onDelete: .cascade)
                t.column("ts", .datetime).notNull()
                t.column("rr_ms", .double).notNull()
            }
            try db.create(index: "live_rr_session", on: "live_rr", columns: ["session_id"])
        }

        migrator.registerMigration("v3_google_health") { db in
            try db.create(table: "daily_metrics") { t in
                t.primaryKey("date", .text)                    // YYYY-MM-DD, user's local day
                t.column("resting_hr", .double)
                t.column("hrv_rmssd_ms", .double)              // sleep-based, from Google
                t.column("sleep_minutes", .integer)
                t.column("sleep_start", .datetime)
                t.column("sleep_end", .datetime)
                t.column("deep_min", .integer)
                t.column("rem_min", .integer)
                t.column("light_min", .integer)
                t.column("awake_min", .integer)
                t.column("steps", .integer)
                t.column("spo2_avg", .double)
                t.column("resp_rate", .double)
                t.column("vo2max", .double)
                t.column("source", .text)
                t.column("updated_at", .datetime)
            }
            try db.create(table: "workouts") { t in
                t.primaryKey("id", .text)
                t.column("start", .datetime).notNull().indexed()
                t.column("end", .datetime)
                t.column("type", .text)
                t.column("avg_hr", .double)
                t.column("max_hr", .integer)
                t.column("source", .text)
            }
            try db.create(table: "sync_state") { t in
                t.primaryKey("data_type", .text)
                t.column("last_success", .datetime)
                t.column("cursor", .text)                      // last fully-synced local date
                t.column("last_error", .text)
            }
        }
        return migrator
    }
}

// MARK: - Settings (key/value)

extension AppDatabase {
    public func setSetting(_ key: String, _ value: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO settings (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [key, value]
            )
        }
    }

    public func setting(_ key: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
        }
    }
}
