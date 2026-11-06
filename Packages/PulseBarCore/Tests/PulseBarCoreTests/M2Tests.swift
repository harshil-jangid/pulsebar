import Foundation
import GRDB
import Testing
@testable import PulseBarCore

/// Fixed UTC calendar so tests don't depend on the machine's time zone.
let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// 2026-11-04 is a Wednesday.
func at(_ hour: Int, _ minute: Int = 0, day: Int = 4) -> Date {
    utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

@Suite("DailyWindow & settings")
struct SettingsTests {
    @Test("normal and overnight windows")
    func windows() {
        let work = DailyWindow(startHour: 9, endHour: 18)
        #expect(work.contains(at(9), calendar: utc))
        #expect(!work.contains(at(18), calendar: utc)) // end is exclusive
        let quiet = DailyWindow(startHour: 22, endHour: 7)
        #expect(quiet.contains(at(23), calendar: utc))
        #expect(quiet.contains(at(6, 59), calendar: utc))
        #expect(!quiet.contains(at(7), calendar: utc))
        #expect(!DailyWindow(start: 0, end: 0).contains(at(12), calendar: utc))
    }

    @Test("work time respects work days")
    func workDays() {
        let s = AppSettings()
        #expect(s.isWorkTime(at(10), calendar: utc))           // Wednesday
        #expect(!s.isWorkTime(at(10, day: 8), calendar: utc))  // Sunday
    }

    @MainActor @Test("settings persist and old JSON with missing keys still decodes")
    func persistence() throws {
        let db = try AppDatabase.inMemory()
        let store = SettingsStore(db: db)
        store.update { $0.age = 31; $0.nudgeThresholdBPM = 30 }
        #expect(SettingsStore(db: db).value.age == 31)
        #expect(SettingsStore(db: db).value.nudgeThresholdBPM == 30)

        try db.setSetting(AppSettings.storageKey, #"{"age": 40}"#)
        let old = SettingsStore(db: db).value
        #expect(old.age == 40)
        #expect(old.nudgeSustainedMinutes == 10) // default filled in
    }
}

@Suite("LiveHRV")
struct LiveHRVTests {
    @Test("RMSSD of alternating 800/850 ms is 50 ms")
    func basic() throws {
        let rr = (0..<12).map { $0.isMultiple(of: 2) ? 800.0 : 850.0 }
        #expect(try #require(LiveHRV.rmssd(rr)) == 50)
    }

    @Test("too few intervals → nil")
    func tooFew() { #expect(LiveHRV.rmssd([800, 810, 820]) == nil) }

    @Test("implausible values and >20% jumps are ignored")
    func artifacts() throws {
        var rr = (0..<12).map { $0.isMultiple(of: 2) ? 800.0 : 850.0 }
        rr.insert(5000, at: 3)   // out of range: dropped
        rr.insert(1300, at: 7)   // ectopic-like jump: its differences skipped
        let value = try #require(LiveHRV.rmssd(rr))
        #expect(value == 50)
    }
}

@MainActor
@Suite("SessionRecorder")
struct SessionRecorderTests {
    let db = try! AppDatabase.inMemory()

    func m(_ bpm: Int, rr: [Double] = []) -> HeartRateMeasurement {
        HeartRateMeasurement(bpm: bpm, sensorContact: .detected, rrIntervalsMs: rr)
    }

    @Test("desk session starts on first sample, ends on disconnect with summary")
    func deskSession() throws {
        let rec = SessionRecorder(db: db)
        rec.handle(.connection(.connected(name: "Strap")))
        let t0 = at(10)
        for i in 0..<20 {
            rec.handle(.measurement(m(70 + i % 3, rr: [800 + Double(i % 2) * 50]), at: t0.addingTimeInterval(Double(i))))
        }
        #expect(rec.current?.kind == .desk)
        rec.handle(.connection(.idle))
        #expect(rec.current == nil)

        let sessions = try db.sessions(from: at(0), to: at(23))
        #expect(sessions.count == 1)
        let s = try #require(sessions.first)
        #expect(s.deviceName == "Strap")
        #expect(s.maxHR == 72)
        #expect(s.end == t0.addingTimeInterval(19))
        #expect(s.liveRMSSDms == 50)
        let n = try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM live_samples") }
        #expect(n == 20)
    }

    @Test("workout splits sessions; no-contact readings aren't stored")
    func workout() throws {
        let rec = SessionRecorder(db: db)
        rec.record(m(70), at: at(10))
        rec.startWorkout(at: at(10, 5))
        #expect(rec.isWorkout)
        rec.record(m(130), at: at(10, 6))
        rec.record(HeartRateMeasurement(bpm: 0, sensorContact: .notDetected), at: at(10, 7))
        rec.endWorkout(at: at(10, 30))
        rec.record(m(75), at: at(10, 31))
        rec.endSession(at: at(10, 32))

        let kinds = try db.sessions(from: at(0), to: at(23)).map(\.kind)
        #expect(kinds == [.desk, .workout, .desk])
        let workout = try db.sessions(from: at(0), to: at(23))[1]
        #expect(workout.maxHR == 130)
        #expect(workout.duration == TimeInterval(25 * 60))
    }

    @Test("a long gap starts a new session")
    func gap() throws {
        let rec = SessionRecorder(db: db, maxGap: 300)
        rec.record(m(70), at: at(10))
        rec.record(m(70), at: at(10, 20))
        rec.endSession(at: at(10, 21))
        #expect(try db.sessions(from: at(0), to: at(23)).count == 2)
    }

    @Test("crash recovery closes open sessions using the last flushed sample")
    func recovery() throws {
        let rec = SessionRecorder(db: db, flushEvery: 0)
        rec.record(m(70), at: at(10))
        rec.record(m(90), at: at(10, 1))
        // Simulated crash: recorder disappears without endSession.
        try db.recoverOpenSessions()
        let s = try #require(try db.sessions(from: at(0), to: at(23)).first)
        #expect(s.end == at(10, 1))
        #expect(s.maxHR == 90)
        #expect(s.avgHR == 80)
    }

    @Test("sessions persist across a reopen of the database file")
    func persistence() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "pb-\(UUID().uuidString)/pulsebar.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let disk = try AppDatabase.openShared(at: url)
            let rec = SessionRecorder(db: disk)
            rec.record(m(70), at: at(10))
            rec.endSession(at: at(10, 1))
        }
        let reopened = try AppDatabase.openShared(at: url)
        #expect(try reopened.sessions(from: at(0), to: at(23)).count == 1)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }
}

@Suite("NudgeEngine")
final class NudgeEngineTests {
    var settings = AppSettings() // threshold 25, 10 min, 1/hour, work 9–18 Mon–Fri, quiet 22–7

    /// Feeds one sample per 30 s from `start` for `minutes`; returns fire times.
    func feed(_ engine: inout NudgeEngine, bpm: Int, from start: Date, minutes: Int,
              resting: Int = 65, workout: Bool = false) -> [Date] {
        var fired: [Date] = []
        for i in 0...(minutes * 2) {
            let t = start.addingTimeInterval(Double(i) * 30)
            if engine.ingest(bpm: bpm, at: t, restingHR: resting, inWorkout: workout,
                             settings: settings, calendar: utc) { fired.append(t) }
        }
        return fired
    }

    @Test("fires once after 10 sustained minutes above resting + 25")
    func firesOnce() {
        var e = NudgeEngine()
        let fired = feed(&e, bpm: 95, from: at(10), minutes: 30)
        #expect(fired == [at(10, 10)])
    }

    @Test("below threshold never fires")
    func belowThreshold() {
        var e = NudgeEngine()
        #expect(feed(&e, bpm: 89, from: at(10), minutes: 30).isEmpty)
    }

    @Test("a dip below threshold restarts the clock")
    func dipResets() {
        var e = NudgeEngine()
        _ = feed(&e, bpm: 95, from: at(10), minutes: 9)
        _ = e.ingest(bpm: 70, at: at(10, 9, ), restingHR: 65, inWorkout: false, settings: settings, calendar: utc)
        let fired = feed(&e, bpm: 95, from: at(10, 9).addingTimeInterval(30), minutes: 12)
        #expect(fired == [at(10, 19).addingTimeInterval(30)])
    }

    @Test("rate limit: at most one per hour")
    func rateLimit() {
        var e = NudgeEngine()
        let fired = feed(&e, bpm: 100, from: at(10), minutes: 90)
        #expect(fired == [at(10, 10), at(11, 10)])
    }

    @Test("silent during workouts, outside work hours, on weekends, in quiet hours")
    func suppressed() {
        var e = NudgeEngine()
        #expect(feed(&e, bpm: 120, from: at(10), minutes: 30, workout: true).isEmpty)
        e = NudgeEngine()
        #expect(feed(&e, bpm: 120, from: at(19), minutes: 30).isEmpty)
        e = NudgeEngine()
        #expect(feed(&e, bpm: 120, from: at(10, day: 8), minutes: 30).isEmpty)
        settings.workHours = DailyWindow(startHour: 0, endHour: 23)
        e = NudgeEngine()
        #expect(feed(&e, bpm: 120, from: at(22, 10), minutes: 30).isEmpty)
    }

    @Test("a data gap restarts the clock")
    func gap() {
        var e = NudgeEngine()
        _ = feed(&e, bpm: 100, from: at(10), minutes: 8)
        let fired = feed(&e, bpm: 100, from: at(10, 12), minutes: 9)
        #expect(fired.isEmpty)
    }

    @Test("disabled → never fires")
    func disabled() {
        settings.nudgeEnabled = false
        var e = NudgeEngine()
        #expect(feed(&e, bpm: 130, from: at(10), minutes: 30).isEmpty)
    }

    @Test("wording is calm and non-diagnostic")
    func wording() {
        let text = NudgeEngine.title + NudgeEngine.body(minutes: 10)
        for word in ["danger", "warning", "abnormal", "risk", "alert"] {
            #expect(!text.lowercased().contains(word))
        }
    }
}
