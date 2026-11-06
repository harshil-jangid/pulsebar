import Foundation
import GRDB
import Testing
@testable import PulseBarCore

@MainActor
@Suite("Data control & updates")
struct M7Tests {
    let db = try! AppDatabase.inMemory()
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func seed() throws {
        try db.writer.write { try $0.execute(sql: "INSERT INTO daily_metrics (date, resting_hr, hrv_rmssd_ms) VALUES ('2026-11-05', 60, 42)") }
        var c = Checkin(nightOf: "2026-11-04"); c.note = "Dinner, then \"late\" call"
        try db.saveCheckin(c)
        let rec = SessionRecorder(db: db)
        rec.record(HeartRateMeasurement(bpm: 70, sensorContact: .detected, rrIntervalsMs: [850]), at: t0)
        rec.endSession(at: t0.addingTimeInterval(60))
        SettingsStore(db: db).update { $0.age = 30 }
    }

    @Test("export writes a CSV per table and a JSON file with everything; CSV escapes quotes and commas")
    func export() throws {
        try seed()
        let dir = FileManager.default.temporaryDirectory.appending(path: "pb-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try db.export(to: dir)
        #expect(files.count == AppDatabase.dataTables.count + 1)
        let checkins = try String(contentsOf: dir.appending(path: "checkins.csv"), encoding: .utf8)
        #expect(checkins.contains(#""Dinner, then ""late"" call""#))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: "pulsebar.json"))) as! [String: Any]
        #expect((json["daily_metrics"] as! [[String: Any]]).first?["resting_hr"] as? String == "60.0")
        #expect((json["live_sessions"] as! [Any]).count == 1)
    }

    @Test("delete all data empties every table; the app keeps working afterwards")
    func deleteAll() throws {
        try seed()
        try db.deleteAllData()
        for t in AppDatabase.dataTables {
            #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(t)") } == 0, "\(t)")
        }
        #expect(SettingsStore(db: db).value == AppSettings())
        try db.saveGoal(Goal(label: "New", goalDate: "2027-01-01"))
        #expect(try db.goal()?.label == "New")
    }

    @Test("retention removes raw samples older than 90 days but keeps session summaries")
    func retention() throws {
        try seed()
        let removed = try db.pruneLiveSamples(olderThan: 90, now: t0.addingTimeInterval(91 * 86_400))
        #expect(removed == 1)
        let samples = try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM live_samples") }
        let rr = try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM live_rr") }
        #expect(samples == 0 && rr == 0)
        #expect(try db.sessions(from: .distantPast, to: .distantFuture).first?.maxHR == 70)
        #expect(try db.pruneLiveSamples(olderThan: 90, now: t0.addingTimeInterval(10 * 86_400)) == 0)
    }

    @Test("version comparison and release parsing")
    func updates() throws {
        #expect(UpdateCheck.compare("1.10.0", "1.9.2") == 1)
        #expect(UpdateCheck.compare("1.0", "1.0.0") == 0)
        #expect(UpdateCheck.compare("0.9.9", "1.0.0") == -1)
        let body = Data(#"{"tag_name":"v1.2.0","html_url":"https://github.com/harshil-jangid/pulsebar/releases/tag/v1.2.0","draft":false,"prerelease":false}"#.utf8)
        #expect(try UpdateCheck.parse(body, current: "1.0.0")?.version == "1.2.0")
        #expect(try UpdateCheck.parse(body, current: "1.2.0") == nil)
        let pre = Data(#"{"tag_name":"v9.0.0","html_url":"https://x","prerelease":true}"#.utf8)
        #expect(try UpdateCheck.parse(pre, current: "1.0.0") == nil)
        #expect(UpdateCheck.isDue(lastCheck: nil))
        #expect(!UpdateCheck.isDue(lastCheck: t0, now: t0.addingTimeInterval(3600)))
    }

    @Test("update check sends no identifiers and treats 404 (no releases) as up to date")
    func updateRequest() async throws {
        let transport = MockTransport()
        transport.on("api.github.com", .init(status: 404, body: "{}"))
        #expect(try await UpdateCheck.newer(than: "1.0.0", transport: transport) == nil)
        let req = try #require(transport.requests.first)
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "PulseBar")
        #expect(req.url?.query == nil)
    }
}
