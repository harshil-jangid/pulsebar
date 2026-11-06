import Foundation
import GRDB

/// One row of `daily_metrics` (from Google Health).
public struct DailyMetric: Codable, Sendable, Equatable, FetchableRecord, TableRecord {
    public static let databaseTableName = "daily_metrics"

    public var date: String
    public var restingHR: Double?
    public var hrvMs: Double?
    public var sleepMinutes: Int?
    public var sleepStart: Date?
    public var sleepEnd: Date?
    public var deepMin: Int?
    public var remMin: Int?
    public var lightMin: Int?
    public var awakeMin: Int?
    public var steps: Int?
    public var spo2: Double?
    public var respRate: Double?
    public var vo2max: Double?

    enum CodingKeys: String, CodingKey {
        case date
        case restingHR = "resting_hr"
        case hrvMs = "hrv_rmssd_ms"
        case sleepMinutes = "sleep_minutes"
        case sleepStart = "sleep_start"
        case sleepEnd = "sleep_end"
        case deepMin = "deep_min"
        case remMin = "rem_min"
        case lightMin = "light_min"
        case awakeMin = "awake_min"
        case steps
        case spo2 = "spo2_avg"
        case respRate = "resp_rate"
        case vo2max
    }

    public init(date: String, restingHR: Double? = nil, hrvMs: Double? = nil, sleepMinutes: Int? = nil, steps: Int? = nil) {
        self.date = date
        self.restingHR = restingHR
        self.hrvMs = hrvMs
        self.sleepMinutes = sleepMinutes
        self.steps = steps
    }

    public func value(_ metric: Metric) -> Double? {
        switch metric {
        case .restingHR: restingHR
        case .hrv: hrvMs
        case .sleep: sleepMinutes.map(Double.init)
        case .steps: steps.map(Double.init)
        }
    }
}

/// The metrics with personal baselines and charts.
public enum Metric: String, CaseIterable, Codable, Sendable, Identifiable {
    case restingHR = "resting_hr"
    case hrv
    case sleep
    case steps

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .restingHR: "Resting heart rate"
        case .hrv: "Sleep HRV"
        case .sleep: "Sleep"
        case .steps: "Steps"
        }
    }

    public var unit: String {
        switch self {
        case .restingHR: "bpm"
        case .hrv: "ms"
        case .sleep: "min"
        case .steps: "steps"
        }
    }

    /// Whether a higher value is the good direction.
    public var higherIsBetter: Bool { self != .restingHR }
}

extension AppDatabase {
    /// Daily rows with `from <= date < to` (YYYY-MM-DD), ascending.
    public func dailyMetrics(from: String, to: String) throws -> [DailyMetric] {
        try writer.read { db in
            try DailyMetric.filter(Column("date") >= from && Column("date") < to).order(Column("date")).fetchAll(db)
        }
    }

    public func allDailyMetrics() throws -> [DailyMetric] {
        try writer.read { try DailyMetric.order(Column("date")).fetchAll($0) }
    }
}
