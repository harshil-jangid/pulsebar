import Foundation

// Minimal Decodable mirrors of the Google Health API v4 resources PulseBar reads.
// Field names and shapes come from the official discovery document
// (https://health.googleapis.com/$discovery/rest?version=v4, revision 20261105).
// Only fields we use are declared; unknown fields are ignored.

/// The data types PulseBar syncs (path IDs from developers.google.com/health/data-types).
public enum GoogleDataType: String, CaseIterable, Sendable {
    case restingHeartRate = "daily-resting-heart-rate"
    case heartRateVariability = "daily-heart-rate-variability"
    case sleep = "sleep"
    case steps = "steps"
    case exercise = "exercise"
    case oxygenSaturation = "daily-oxygen-saturation"
    case respiratoryRate = "daily-respiratory-rate"
    case vo2Max = "daily-vo2-max"

    /// Filter field for a civil-date range (google.aip.dev/160 syntax from the API docs).
    func filter(from: String, to: String) -> String {
        let field: String = switch self {
        case .restingHeartRate: "daily_resting_heart_rate.date"
        case .heartRateVariability: "daily_heart_rate_variability.date"
        case .oxygenSaturation: "daily_oxygen_saturation.date"
        case .respiratoryRate: "daily_respiratory_rate.date"
        case .vo2Max: "daily_vo2_max.date"
        case .sleep: "sleep.interval.civil_end_time"
        case .steps: "steps.interval.civil_start_time"
        case .exercise: "exercise.interval.civil_start_time"
        }
        return "\(field) >= \"\(from)\" AND \(field) < \"\(to)\""
    }

    /// Human-readable purpose, shown in the in-app disclosure (policy requirement).
    public var disclosure: String {
        switch self {
        case .restingHeartRate: "Daily resting heart rate: your personal baseline and readiness"
        case .heartRateVariability: "Daily heart-rate variability (during sleep): recovery baseline and readiness"
        case .sleep: "Sleep sessions and stages: sleep duration in readiness and trends"
        case .steps: "Steps: daily activity trends"
        case .exercise: "Exercise sessions: workout history and habit insights"
        case .oxygenSaturation: "Blood-oxygen average during sleep: shown in trends only"
        case .respiratoryRate: "Breathing rate during sleep: shown in trends only"
        case .vo2Max: "VO2 max (cardio fitness estimate): shown in trends only"
        }
    }

    /// The three read-only scopes covering these types (least privilege, §11 Q1).
    public static let scopes = [
        "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly",
        "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
        "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
    ]
}

/// int64 fields arrive as JSON strings ("62"); accept numbers too.
struct FlexInt: Decodable, Sendable {
    let value: Int
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = i; return }
        let s = try c.decode(String.self)
        guard let i = Int(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an integer: \(s)")
        }
        value = i
    }
}

struct GDate: Decodable, Sendable {
    let year: Int
    let month: Int
    let day: Int
    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

struct GCivilDateTime: Decodable, Sendable {
    let date: GDate
}

struct GInterval: Decodable, Sendable {
    let startTime: String
    let endTime: String
    let civilStartTime: GCivilDateTime?
    let civilEndTime: GCivilDateTime?
}

struct GDailyRestingHeartRate: Decodable, Sendable {
    let beatsPerMinute: FlexInt
    let date: GDate
}

struct GDailyHRV: Decodable, Sendable {
    let averageHeartRateVariabilityMilliseconds: Double?
    let date: GDate
}

struct GSleep: Decodable, Sendable {
    struct Summary: Decodable, Sendable {
        struct Stage: Decodable, Sendable {
            let type: String
            let minutes: FlexInt?
        }
        let minutesAsleep: FlexInt?
        let minutesAwake: FlexInt?
        let stagesSummary: [Stage]?
    }
    struct Metadata: Decodable, Sendable {
        let mainSleep: Bool?
        let nap: Bool?
    }
    let interval: GInterval
    let summary: Summary?
    let metadata: Metadata?
}

struct GSteps: Decodable, Sendable {
    let interval: GInterval
    let count: FlexInt
}

struct GExercise: Decodable, Sendable {
    struct Metrics: Decodable, Sendable {
        let averageHeartRateBeatsPerMinute: FlexInt?
    }
    let interval: GInterval
    let exerciseType: String?
    let displayName: String?
    let metricsSummary: Metrics?
}

struct GDailyOxygenSaturation: Decodable, Sendable {
    let averagePercentage: Double
    let date: GDate
}

struct GDailyRespiratoryRate: Decodable, Sendable {
    let breathsPerMinute: Double
    let date: GDate
}

struct GDailyVO2Max: Decodable, Sendable {
    let vo2Max: Double
    let date: GDate
}

/// One element of `ReconcileDataPointsResponse.dataPoints` (union: one field is set).
struct GReconciledDataPoint: Decodable, Sendable {
    let dataPointName: String?
    let dailyRestingHeartRate: GDailyRestingHeartRate?
    let dailyHeartRateVariability: GDailyHRV?
    let sleep: GSleep?
    let steps: GSteps?
    let exercise: GExercise?
    let dailyOxygenSaturation: GDailyOxygenSaturation?
    let dailyRespiratoryRate: GDailyRespiratoryRate?
    let dailyVo2Max: GDailyVO2Max?
}

struct GReconcileResponse: Decodable, Sendable {
    let dataPoints: [GReconciledDataPoint]?
    let nextPageToken: String?
}

/// RFC 3339 timestamps, with or without fractional seconds.
enum GoogleTime {
    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
