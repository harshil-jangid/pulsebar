import Foundation
import Testing
@testable import PulseBarCore

@Suite("Check-ins")
struct CheckinTests {
    @Test("a check-in is attributed to the night that follows; after-midnight counts as the previous night")
    func attribution() {
        let evening = utc.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 22))!
        let lateNight = utc.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 1, minute: 30))!
        #expect(Checkin.nightOf(evening, calendar: utc) == "2026-11-05")
        #expect(Checkin.nightOf(lateNight, calendar: utc) == "2026-11-05")
        #expect(Checkin(nightOf: "2026-11-05").nextMorning == "2026-11-06")
    }

    @Test("save/load round trip including custom tags and note; saving twice replaces")
    func roundTrip() throws {
        let db = try AppDatabase.inMemory()
        var c = Checkin(nightOf: "2026-11-05")
        c.alcohol = .some
        c.workout = .hard
        c.workoutType = "Run"
        c.stress = 4
        c.note = "Long day"
        c.custom = ["t1": true]
        try db.saveCheckin(c)
        c.lateScreens = true
        try db.saveCheckin(c)
        #expect(try db.checkin(nightOf: "2026-11-05") == c)
        #expect(try db.latestCheckin()?.nightOf == "2026-11-05")
        let rows = try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(DISTINCT night_of) FROM checkins") }
        #expect(rows == 1)
    }
}

@Suite("Habit insights")
struct HabitInsightTests {
    /// 60 days; check-ins for nights 35…58; alcohol every 3rd night, followed by a low-HRV morning.
    func data(nights: ClosedRange<Int> = 35...58) -> ([DailyMetric], [Checkin]) {
        let start = "2026-09-01"
        var rows: [DailyMetric] = []
        var alcoholMornings = Set<String>()
        var checkins: [Checkin] = []
        for j in nights {
            var c = Checkin(nightOf: LocalDay.adding(j, to: start, utc)!)
            c.alcohol = j % 3 == 0 ? .some : .none
            c.stress = 3 // neither high nor low → excluded from the stress comparison
            if c.alcohol != .none { alcoholMornings.insert(c.nextMorning) }
            checkins.append(c)
        }
        for i in 0..<60 {
            let day = LocalDay.adding(i, to: start, utc)!
            let low = alcoholMornings.contains(day)
            rows.append(DailyMetric(date: day, restingHR: low ? 64 : 60, hrvMs: low ? 34 : (i.isMultiple(of: 2) ? 42 : 44)))
        }
        return (rows, checkins)
    }

    @Test("alcohol nights → lower next-morning HRV, association wording with counts")
    func alcohol() throws {
        let (rows, checkins) = data()
        let insights = HabitInsights.compute(metric: .hrv, checkins: checkins, rows: rows, calendar: utc)
        let alcohol = try #require(insights.first { $0.conditionID == "alcohol" })
        #expect(alcohol.withCount == 8)
        #expect(alcohol.withoutCount == 16)
        #expect(alcohol.rawDifference < 0)
        #expect(alcohol.sentence.hasPrefix("On nights after alcohol, your next-morning HRV averaged"))
        #expect(alcohol.sentence.hasSuffix("lower (8 vs 16 nights)."))
        #expect(alcohol.confidence != .weak)

        let rhr = try #require(HabitInsights.compute(metric: .restingHR, checkins: checkins, rows: rows, calendar: utc)
            .first { $0.conditionID == "alcohol" })
        #expect(rhr.sentence == "On nights after alcohol, your next-morning resting HR averaged 4 bpm higher (8 vs 16 nights).")
    }

    @Test("hidden below 5 nights per group")
    func threshold() {
        let (rows, checkins) = data(nights: 35...46)   // 12 nights → 4 alcohol nights
        let insights = HabitInsights.compute(metric: .hrv, checkins: checkins, rows: rows, calendar: utc)
        #expect(insights.first { $0.conditionID == "alcohol" } == nil)
    }

    @Test("conditions with no 'yes' nights produce nothing; mid stress is excluded")
    func noData() {
        let (rows, checkins) = data()
        let ids = HabitInsights.compute(metric: .hrv, checkins: checkins, rows: rows, calendar: utc).map(\.conditionID)
        #expect(!ids.contains("late_meal"))
        #expect(!ids.contains("high_stress"))
    }

    @Test("wording never claims causation")
    func wording() {
        let (rows, checkins) = data()
        for i in HabitInsights.compute(metric: .hrv, checkins: checkins, rows: rows, calendar: utc) {
            for word in ["cause", "because", "leads to", "makes your", "due to"] {
                #expect(!i.sentence.lowercased().contains(word))
            }
        }
    }
}
