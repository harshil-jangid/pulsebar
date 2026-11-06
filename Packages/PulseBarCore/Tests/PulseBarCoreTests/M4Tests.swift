import Foundation
import Testing
@testable import PulseBarCore

/// 30 days before 2026-11-05 with alternating values, plus "today".
func fixtureRows(days: Int = 30, today: DailyMetric? = DailyMetric(date: "2026-11-05", restingHR: 59, hrvMs: 48, sleepMinutes: 400)) -> [DailyMetric] {
    var rows: [DailyMetric] = (1...days).map { i in
        let day = LocalDay.adding(-i, to: "2026-11-05", utc)!
        let even = i.isMultiple(of: 2)
        return DailyMetric(date: day, restingHR: even ? 60 : 62, hrvMs: even ? 40 : 44,
                           sleepMinutes: even ? 420 : 440, steps: even ? 6000 : 8000)
    }
    rows.reverse()
    if let today { rows.append(today) }
    return rows
}

@Suite("Robust stats & baselines")
struct BaselineTests {
    @Test("median and MAD")
    func stats() {
        #expect(RobustStats.median([3, 1, 2]) == 2)
        #expect(RobustStats.median([4, 1, 2, 3]) == 2.5)
        #expect(RobustStats.median([]) == nil)
        #expect(RobustStats.mad([1, 1, 2, 2, 4, 6, 9]) == 1)
    }

    @Test("baseline uses the 30 days before today, not today")
    func window() throws {
        let b = try #require(Baseline.compute(.hrv, before: "2026-11-05", in: fixtureRows(), calendar: utc))
        #expect(b.median == 42)
        #expect(b.mad == 2)
        #expect(b.validDays == 30)
        #expect(b.isCalibrated)
    }

    @Test("z is clipped to ±3 and uses a floor when MAD is 0")
    func zScore() {
        let b = Baseline(median: 60, mad: 0, validDays: 20)
        #expect(b.z(61, floor: 0.5) == 2)
        #expect(b.z(80, floor: 0.5) == 3)
        #expect(b.z(10, floor: 0.5) == -3)
    }

    @Test("LocalDay rejects impossible dates")
    func localDay() {
        #expect(LocalDay.parse("2026-02-31", utc) == nil)
        #expect(LocalDay.parse("nonsense", utc) == nil)
        #expect(LocalDay.adding(1, to: "2026-12-31", utc) == "2027-01-01")
    }
}

@Suite("Readiness")
struct ReadinessTests {
    @Test("worked example: score 60 → Go hard, with numeric reasons")
    func workedExample() {
        // HRV: median 42, MAD 2 → z = 6 / 2.9652 = 2.0235
        // RHR: median 61, MAD 1 → z(59) = −1.349 → rhr_z = +1.349
        // Sleep: median 430, MAD 10 → z(400) = −2.0235
        // 0.5·2.0235 + 0.3·1.349 + 0.2·(−2.0235) = 1.0118 → 50 + 10.118 = 60
        let r = Readiness.compute(date: "2026-11-05", rows: fixtureRows(), calendar: utc)
        #expect(r.state == .ready)
        #expect(r.score == 60)
        #expect(r.band == .goHard)
        #expect(r.reasons == ["HRV 14% above your baseline", "resting HR 2 bpm below baseline", "sleep 30 min short"])
    }

    @Test("band boundaries", arguments: [(100, ReadinessBand.goHard), (60, .goHard), (59, .normal),
                                         (40, .normal), (39, .takeItEasy), (0, .takeItEasy)])
    func bands(score: Int, band: ReadinessBand) { #expect(ReadinessBand.of(score: score) == band) }

    @Test("calibrating below 14 valid days")
    func calibrating() {
        let r = Readiness.compute(date: "2026-11-05", rows: fixtureRows(days: 9), calendar: utc)
        #expect(r.state == .calibrating(days: 9))
        #expect(r.summary == "Calibrating (9/14 days)")
        #expect(r.score == nil)
    }

    @Test("no data today → noData, not a fake score")
    func noData() {
        let r = Readiness.compute(date: "2026-11-05", rows: fixtureRows(today: nil), calendar: utc)
        #expect(r.state == .noData)
    }

    @Test("missing sleep re-normalizes weights")
    func missingSleep() {
        let rows = fixtureRows(today: DailyMetric(date: "2026-11-05", restingHR: 59, hrvMs: 48))
        let r = Readiness.compute(date: "2026-11-05", rows: rows, calendar: utc)
        // (0.5·2.0235 + 0.3·1.349) / 0.8 = 1.7706 → 67.7 → 68
        #expect(r.score == 68)
        #expect(r.components.map(\.metric) == [.hrv, .restingHR])
    }

    @Test("terrible night → Take it easy")
    func takeItEasy() {
        let rows = fixtureRows(today: DailyMetric(date: "2026-11-05", restingHR: 70, hrvMs: 30, sleepMinutes: 300))
        let r = Readiness.compute(date: "2026-11-05", rows: rows, calendar: utc)
        #expect(r.score == 20)
        #expect(r.band == .takeItEasy)
    }
}

@Suite("Goal, trends, morning card")
struct GoalTrendTests {
    @Test("days remaining")
    func countdown() {
        #expect(Goal(label: "Wedding", goalDate: "2027-02-14").daysRemaining(from: "2026-11-06", calendar: utc) == 100)
    }

    @Test("start snapshot freezes the first 14 valid days")
    func snapshot() throws {
        let snap = try #require(StartSnapshot.compute(from: fixtureRows()))
        #expect(snap.fromDate == "2026-10-06")
        #expect(snap.toDate == "2026-10-19")
        #expect(snap.values[.hrv] == 42)
        #expect(StartSnapshot.compute(from: Array(fixtureRows().prefix(5))) == nil)
    }

    @Test("goal persists; snapshot is set once and not overwritten")
    func goalStore() throws {
        let db = try AppDatabase.inMemory()
        try db.saveGoal(Goal(label: "Wedding", goalDate: "2027-02-14"))
        #expect(try db.ensureStartSnapshot()?.startSnapshot == nil) // no data yet
        try db.writer.write { d in
            for r in fixtureRows() {
                try d.execute(sql: "INSERT INTO daily_metrics (date, resting_hr, hrv_rmssd_ms, sleep_minutes) VALUES (?,?,?,?)",
                              arguments: [r.date, r.restingHR, r.hrvMs, r.sleepMinutes])
            }
        }
        let first = try #require(try db.ensureStartSnapshot()?.startSnapshot)
        try db.writer.write { try $0.execute(sql: "UPDATE daily_metrics SET hrv_rmssd_ms = 99") }
        #expect(try db.ensureStartSnapshot()?.startSnapshot == first)
    }

    @Test("daily trend has a 7-day rolling mean; weekly buckets average")
    func trends() {
        let rows = fixtureRows(today: nil)
        let daily = Trends.series(.steps, rows: rows, period: .day, calendar: utc)
        #expect(daily.count == 30)
        #expect(daily.first?.rolling7 == nil)          // needs ≥3 days
        #expect(daily.last?.rolling7 != nil)
        let weekly = Trends.series(.steps, rows: rows, period: .week, calendar: utc)
        #expect(weekly.allSatisfy { (6000...8000).contains($0.value) })
        #expect(weekly.reduce(0) { $0 + $1.count } == 30)
    }

    @Test("morning card: once a day, after the chosen time, only with today's data")
    func morningCard() {
        let readiness = Readiness.compute(date: "2026-11-05", rows: fixtureRows(), calendar: utc)
        var s = AppSettings()
        s.morningReadinessMinute = 8 * 60
        let early = utc.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 7, minute: 30))!
        let later = utc.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 8, minute: 5))!
        #expect(MorningCard.message(now: early, settings: s, readiness: readiness, calendar: utc) == nil)
        let msg = MorningCard.message(now: later, settings: s, readiness: readiness, calendar: utc)
        #expect(msg?.title == "Today: Go hard")
        #expect(msg?.body == "HRV 14% above your baseline")
        s.lastMorningNotificationDay = "2026-11-05"
        #expect(MorningCard.message(now: later, settings: s, readiness: readiness, calendar: utc) == nil)
    }
}
