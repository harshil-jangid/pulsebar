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
        try AppDatabase(DatabaseQueue())
    }

    /// Read-only connection to an existing database file (used by the MCP server).
    /// Runs no migrations; it only reads what the app has written.
    public static func openReadOnly(at url: URL) throws -> any DatabaseReader {
        var config = Configuration()
        config.readonly = true
        return try DatabaseQueue(path: url.path, configuration: config)
    }

    /// Ordered, append-only list of schema changes. Never edit a shipped
    /// migration; add a new one instead.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // Rebuild from scratch when a migration changes during development.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_settings") { db in
            try db.create(table: "settings") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        // Later milestones add: live_sessions, live_samples (M2),
        // daily_metrics, workouts, sync_state (M3), goal (M4), checkins (M5).
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
