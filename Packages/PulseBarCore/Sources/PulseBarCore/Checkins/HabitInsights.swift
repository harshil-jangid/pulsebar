import Foundation

/// A yes/no question asked of each check-in, e.g. "had alcohol".
public struct HabitCondition: Sendable, Identifiable, Equatable {
    public let id: String
    /// Phrase used in "On nights after …".
    public let phrase: String
    public let test: @Sendable (Checkin) -> Bool?

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    /// Built-in conditions (F7.1). `nil` from `test` = this night doesn't belong to either group.
    public static func builtIn(customTags: [CustomTag] = []) -> [HabitCondition] {
        var list: [HabitCondition] = [
            .init(id: "alcohol", phrase: "alcohol") { $0.alcohol != .none },
            .init(id: "late_meal", phrase: "a late heavy meal") { $0.lateHeavyMeal },
            .init(id: "caffeine_after_3pm", phrase: "caffeine after 3 pm") { $0.caffeineAfter3pm },
            .init(id: "workout", phrase: "a workout") { $0.workout != .none },
            .init(id: "hard_workout", phrase: "a hard workout") { $0.workout == .none ? nil : $0.workout == .hard },
            .init(id: "home", phrase: "a work-from-home day") { $0.location == .home },
            .init(id: "late_screens", phrase: "late screens") { $0.lateScreens },
            .init(id: "high_stress", phrase: "a stressful day (4–5)") { c in
                c.stress >= 4 ? true : (c.stress <= 2 ? false : nil) },
        ]
        for tag in customTags where !tag.hidden {
            let id = tag.id
            list.append(.init(id: "custom:\(id)", phrase: tag.name.lowercased()) { $0.custom[id] })
        }
        return list
    }
}

public struct HabitInsight: Sendable, Equatable, Identifiable, Codable {
    public enum Confidence: String, Sendable, Codable { case weak = "weak", moderate = "moderate", stronger = "stronger" }

    public let conditionID: String
    public let metric: Metric
    public let withCount: Int
    public let withoutCount: Int
    /// Mean next-morning robust z-score difference (with − without), metric's own direction.
    public let zDifference: Double
    /// Raw difference of group means (ms for HRV, bpm for resting HR).
    public let rawDifference: Double
    public let percentDifference: Double
    public let confidence: Confidence
    /// Association-only wording (F7.2).
    public let sentence: String

    public var id: String { "\(conditionID)-\(metric.rawValue)" }
}

/// Compares next-morning HRV / resting HR (as z-scores vs. the 30-day baseline
/// before that morning) on nights with vs. without each condition (F7).
public enum HabitInsights {
    public static let minimumPerGroup = 5

    /// Insights with at least `minimumPerGroup` nights in BOTH groups; others are hidden (F7.2).
    public static func compute(metric: Metric, checkins: [Checkin], rows: [DailyMetric],
                               conditions: [HabitCondition] = HabitCondition.builtIn(),
                               calendar: Calendar = .current) -> [HabitInsight] {
        precondition(metric == .hrv || metric == .restingHR, "insights are defined for HRV and resting HR")
        // Next-morning value and z for each check-in night (only calibrated baselines).
        let byDate = Dictionary(uniqueKeysWithValues: rows.map { ($0.date, $0) })
        let nights: [(Checkin, Double, Double)] = checkins.compactMap { c in
            guard let morning = byDate[c.nextMorning], let v = morning.value(metric),
                  let base = Baseline.compute(metric, before: c.nextMorning, in: rows, calendar: calendar),
                  base.isCalibrated else { return nil }
            let floor = metric == .hrv ? ReadinessWeights().floorHRVms : ReadinessWeights().floorRestingHR
            return (c, v, base.z(v, floor: floor))
        }
        return conditions.compactMap { cond in
            var with: [(Double, Double)] = [], without: [(Double, Double)] = []
            for (c, v, z) in nights {
                switch cond.test(c) {
                case true?: with.append((v, z))
                case false?: without.append((v, z))
                case nil: break
                }
            }
            guard with.count >= minimumPerGroup, without.count >= minimumPerGroup else { return nil }
            let mw = mean(with.map(\.0)), mo = mean(without.map(\.0))
            let zw = with.map(\.1), zo = without.map(\.1)
            let zDiff = mean(zw) - mean(zo)
            let se = (variance(zw) / Double(zw.count) + variance(zo) / Double(zo.count)).squareRoot()
            let t = se > 0 ? abs(zDiff) / se : 0
            let confidence: HabitInsight.Confidence =
                t >= 2.5 && min(zw.count, zo.count) >= 10 ? .stronger : (t >= 1.5 ? .moderate : .weak)
            let raw = mw - mo
            let pct = mo != 0 ? raw / mo * 100 : 0
            return HabitInsight(conditionID: cond.id, metric: metric, withCount: with.count, withoutCount: without.count,
                                zDifference: zDiff, rawDifference: raw, percentDifference: pct, confidence: confidence,
                                sentence: sentence(cond, metric, raw: raw, pct: pct, with: with.count, without: without.count))
        }
        .sorted { abs($0.zDifference) > abs($1.zDifference) }
    }

    /// "On nights after alcohol, your HRV averaged 14% lower (8 vs 21 nights)."
    static func sentence(_ c: HabitCondition, _ m: Metric, raw: Double, pct: Double, with: Int, without: Int) -> String {
        let counts = "(\(with) vs \(without) nights)"
        switch m {
        case .hrv:
            let p = Int(abs(pct).rounded())
            if p == 0 { return "On nights after \(c.phrase), your next-morning HRV was about the same \(counts)." }
            return "On nights after \(c.phrase), your next-morning HRV averaged \(p)% \(pct > 0 ? "higher" : "lower") \(counts)."
        default:
            let b = Int(abs(raw).rounded())
            if b == 0 { return "On nights after \(c.phrase), your next-morning resting HR was about the same \(counts)." }
            return "On nights after \(c.phrase), your next-morning resting HR averaged \(b) bpm \(raw > 0 ? "higher" : "lower") \(counts)."
        }
    }

    static func mean(_ x: [Double]) -> Double { x.reduce(0, +) / Double(max(x.count, 1)) }

    static func variance(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let m = mean(x)
        return x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count - 1)
    }
}
