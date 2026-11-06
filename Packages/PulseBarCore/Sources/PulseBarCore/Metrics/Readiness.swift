import Foundation

/// Robust statistics used for personal baselines (F4.1).
public enum RobustStats {
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let m = s.count / 2
        return s.count.isMultiple(of: 2) ? (s[m - 1] + s[m]) / 2 : s[m]
    }

    /// Median absolute deviation (unscaled).
    public static func mad(_ values: [Double]) -> Double? {
        guard let med = median(values) else { return nil }
        return median(values.map { abs($0 - med) })
    }
}

/// A personal baseline: 30-day median and MAD of valid days before a date.
public struct Baseline: Sendable, Equatable, Codable {
    public static let windowDays = 30
    public static let minimumDays = 14

    public let median: Double
    public let mad: Double
    public let validDays: Int

    public var isCalibrated: Bool { validDays >= Self.minimumDays }

    /// Baseline from the `windowDays` days strictly before `date` (today is compared, not included).
    public static func compute(_ metric: Metric, before date: String, in rows: [DailyMetric],
                               calendar: Calendar = .current) -> Baseline? {
        guard let end = LocalDay.parse(date, calendar),
              let start = calendar.date(byAdding: .day, value: -windowDays, to: end) else { return nil }
        let from = LocalDay.string(start, calendar)
        let values = rows.filter { $0.date >= from && $0.date < date }.compactMap { $0.value(metric) }
        guard let med = RobustStats.median(values), let mad = RobustStats.mad(values) else { return nil }
        return Baseline(median: med, mad: mad, validDays: values.count)
    }

    /// Robust z-score `(x − median) / (1.4826 × MAD)`, clipped to [−3, 3] (F4.2).
    /// When MAD is ~0 (very stable data), a per-metric floor keeps it from exploding.
    public func z(_ value: Double, floor: Double) -> Double {
        let scale = max(1.4826 * mad, floor)
        return min(3, max(-3, (value - median) / scale))
    }
}

public enum ReadinessBand: String, Sendable, Codable {
    case goHard = "Go hard"
    case normal = "Normal day"
    case takeItEasy = "Take it easy"

    public static func of(score: Int) -> ReadinessBand {
        score >= 60 ? .goHard : (score >= 40 ? .normal : .takeItEasy)
    }

    public var symbol: String {
        switch self {
        case .goHard: "bolt.heart"
        case .normal: "heart"
        case .takeItEasy: "leaf"
        }
    }
}

/// Weights live in one place so they can be tuned (F4.2). v1 heuristic, not clinically validated.
public struct ReadinessWeights: Sendable, Equatable, Codable {
    public var hrv = 0.5
    public var restingHR = 0.3
    public var sleep = 0.2
    /// Minimum z-score denominators when MAD is ~0.
    public var floorHRVms = 1.0
    public var floorRestingHR = 0.5
    public var floorSleepMin = 5.0
    public init() {}
}

public struct Readiness: Sendable, Equatable, Codable {
    public enum State: Sendable, Equatable, Codable {
        case calibrating(days: Int)
        case noData
        case ready
    }

    public struct Component: Sendable, Equatable, Codable {
        public let metric: Metric
        public let today: Double
        public let baseline: Double
        /// Good-direction z (higher = better for readiness).
        public let z: Double
    }

    public let date: String
    public let state: State
    public let score: Int?
    public let band: ReadinessBand?
    public let components: [Component]
    /// Plain-language "why", always with numbers (F4.2).
    public let reasons: [String]

    public var summary: String {
        switch state {
        case .calibrating(let n): "Calibrating (\(n)/\(Baseline.minimumDays) days)"
        case .noData: "No data for today yet"
        case .ready: "\(band?.rawValue ?? ""): \(reasons.joined(separator: ", "))"
        }
    }

    public static func compute(date: String, rows: [DailyMetric], weights: ReadinessWeights = ReadinessWeights(),
                               calendar: Calendar = .current) -> Readiness {
        let today = rows.first { $0.date == date }
        let hrvBase = Baseline.compute(.hrv, before: date, in: rows, calendar: calendar)
        let rhrBase = Baseline.compute(.restingHR, before: date, in: rows, calendar: calendar)
        let sleepBase = Baseline.compute(.sleep, before: date, in: rows, calendar: calendar)

        let calibratedDays = min(hrvBase?.validDays ?? 0, rhrBase?.validDays ?? 0)
        guard calibratedDays >= Baseline.minimumDays else {
            return Readiness(date: date, state: .calibrating(days: calibratedDays), score: nil, band: nil,
                             components: [], reasons: [])
        }
        guard let today, today.hrvMs != nil || today.restingHR != nil else {
            return Readiness(date: date, state: .noData, score: nil, band: nil, components: [], reasons: [])
        }

        var parts: [(Component, Double)] = []
        if let v = today.hrvMs, let b = hrvBase {
            parts.append((Component(metric: .hrv, today: v, baseline: b.median, z: b.z(v, floor: weights.floorHRVms)), weights.hrv))
        }
        if let v = today.restingHR, let b = rhrBase {
            parts.append((Component(metric: .restingHR, today: v, baseline: b.median,
                                    z: -b.z(v, floor: weights.floorRestingHR)), weights.restingHR))
        }
        if let v = today.sleepMinutes.map(Double.init), let b = sleepBase, b.validDays >= Baseline.minimumDays {
            parts.append((Component(metric: .sleep, today: v, baseline: b.median, z: b.z(v, floor: weights.floorSleepMin)), weights.sleep))
        }
        // If a metric is missing today, re-normalize the remaining weights so the scale stays comparable.
        let totalWeight = parts.reduce(0) { $0 + $1.1 }
        let weighted = parts.reduce(0) { $0 + $1.0.z * $1.1 } / totalWeight
        let score = Int(min(100, max(0, (50 + 10 * weighted).rounded())))
        let components = parts.map(\.0)
        return Readiness(date: date, state: .ready, score: score, band: .of(score: score),
                         components: components, reasons: components.map(reason))
    }

    static func reason(_ c: Component) -> String {
        switch c.metric {
        case .hrv:
            let pct = Int(((c.today - c.baseline) / c.baseline * 100).rounded())
            return pct == 0 ? "HRV at your baseline" : "HRV \(abs(pct))% \(pct > 0 ? "above" : "below") your baseline"
        case .restingHR:
            let d = Int((c.today - c.baseline).rounded())
            return d == 0 ? "resting HR at your baseline" : "resting HR \(abs(d)) bpm \(d > 0 ? "above" : "below") baseline"
        case .sleep:
            let d = Int((c.today - c.baseline).rounded())
            return abs(d) < 10 ? "sleep about usual" : "sleep \(abs(d)) min \(d > 0 ? "longer" : "short")"
        case .steps:
            return ""
        }
    }
}
