import Foundation
import GRDB
import Testing
@testable import PulseBarCore

@Suite("AppDatabase")
struct AppDatabaseTests {
    @Test("migrations create the settings table")
    func migrationsRun() throws {
        let db = try AppDatabase.inMemory()
        let exists = try db.writer.read { try $0.tableExists("settings") }
        #expect(exists)
    }

    @Test("settings upsert: second write replaces the first, no duplicate row")
    func settingsUpsert() throws {
        let db = try AppDatabase.inMemory()
        try db.setSetting("units", "metric")
        try db.setSetting("units", "imperial")

        #expect(try db.setting("units") == "imperial")
        #expect(try db.setting("missing") == nil)
        let count = try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM settings") }
        #expect(count == 1)
    }

    @Test("read-only connection cannot write")
    func readOnlyRejectsWrites() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.sqlite")

        let app = try AppDatabase(DatabaseQueue(path: url.path))
        try app.setSetting("goal_label", "Wedding")

        let reader = try AppDatabase.openReadOnly(at: url)
        let value = try reader.read {
            try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key = 'goal_label'")
        }
        #expect(value == "Wedding")

        // A DatabaseQueue is also a writer; prove SQLite itself refuses the write.
        let queue = try #require(reader as? DatabaseQueue)
        #expect(throws: DatabaseError.self) {
            try queue.write { try $0.execute(sql: "INSERT INTO settings VALUES ('x', 'y')") }
        }
    }
}
