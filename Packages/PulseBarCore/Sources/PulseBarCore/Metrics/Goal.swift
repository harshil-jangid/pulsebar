import Foundation
import GRDB

/// The user's goal (F1.2, F5.1). Single row.
public struct Goal: Codable, Sendable, Equatable {
    public var label: String
    public var goalDate: String          // YYYY-MM-DD
    public var intentions: String?
    public var startSnapshot: StartSnapshot?

    public init(label: String, goalDate: String, intentions: String? = nil, startSnapshot: StartSnapshot? = nil) {
        self.label = label
        self.goalDate = goalDate
        self.intentions = intentions
        self.startSnapshot = startSnapshot
    }

    public func daysRemaining(from today: String, calendar: Calendar = .current) -> Int? {
        guard let a = LocalDay.parse(today, calendar), let b = LocalDay.parse(goalDate, calendar) else { return nil }
        return calendar.dateComponents([.day], from: a, to: b).day
    }
}

/// Medians of the first 14 calibrated days, frozen as "where you started" (F5.1).
public struct StartSnapshot: Codable, Sendable, Equatable {
    public var fromDate: String
    public var toDate: String
    public var values: [Metric: Double]

    /// First run of `Baseline.minimumDays` days that have HRV or resting HR.
    public static func compute(from rows: [DailyMetric]) -> StartSnapshot? {
        let valid = rows.filter { $0.hrvMs != nil || $0.restingHR != nil }
        guard valid.count >= Baseline.minimumDays else { return nil }
        let first = Array(valid.prefix(Baseline.minimumDays))
        var values: [Metric: Double] = [:]
        for m in Metric.allCases {
            if let med = RobustStats.median(first.compactMap { $0.value(m) }) { values[m] = med }
        }
        return StartSnapshot(fromDate: first.first!.date, toDate: first.last!.date, values: values)
    }
}

extension AppDatabase {
    public func goal() throws -> Goal? {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT label, goal_date, intentions, start_snapshot_json FROM goal WHERE id = 1") else { return nil }
            let snapshot: StartSnapshot? = (row["start_snapshot_json"] as String?)
                .flatMap { try? JSONDecoder().decode(StartSnapshot.self, from: Data($0.utf8)) }
            return Goal(label: row["label"], goalDate: row["goal_date"], intentions: row["intentions"], startSnapshot: snapshot)
        }
    }

    public func saveGoal(_ goal: Goal) throws {
        let json = try goal.startSnapshot.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO goal (id, label, goal_date, intentions, start_snapshot_json) VALUES (1, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET label = excluded.label, goal_date = excluded.goal_date,
                    intentions = excluded.intentions, start_snapshot_json = excluded.start_snapshot_json
                """, arguments: [goal.label, goal.goalDate, goal.intentions, json])
        }
    }

    /// Freezes the start snapshot the first time enough data exists. Returns the (possibly updated) goal.
    @discardableResult
    public func ensureStartSnapshot() throws -> Goal? {
        guard var goal = try goal(), goal.startSnapshot == nil,
              let snap = StartSnapshot.compute(from: try allDailyMetrics()) else { return try self.goal() }
        goal.startSnapshot = snap
        try saveGoal(goal)
        return goal
    }
}
