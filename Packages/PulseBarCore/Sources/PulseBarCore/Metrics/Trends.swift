import Foundation

public enum TrendPeriod: String, CaseIterable, Sendable, Codable, Identifiable {
    case day, week, month
    public var id: String { rawValue }
}

public struct TrendPoint: Sendable, Equatable, Identifiable, Codable {
    /// Start of the bucket (local midnight).
    public let date: Date
    public let value: Double
    /// 7-day rolling mean (daily view only).
    public let rolling7: Double?
    public let count: Int
    public var id: Date { date }
}

/// Daily points + 7-day rolling average, or weekly / monthly means (F5.2).
public enum Trends {
    public static func series(_ metric: Metric, rows: [DailyMetric], period: TrendPeriod,
                              calendar: Calendar = .current) -> [TrendPoint] {
        let daily: [(Date, Double)] = rows.compactMap { r in
            guard let v = r.value(metric), let d = LocalDay.parse(r.date, calendar) else { return nil }
            return (d, v)
        }
        switch period {
        case .day:
            return daily.map { (date, value) in
                let start = calendar.date(byAdding: .day, value: -6, to: date)!
                let window = daily.filter { $0.0 >= start && $0.0 <= date }.map(\.1)
                return TrendPoint(date: date, value: value,
                                  rolling7: window.count >= 3 ? window.reduce(0, +) / Double(window.count) : nil,
                                  count: 1)
            }
        case .week, .month:
            let component: Calendar.Component = period == .week ? .weekOfYear : .month
            let groups = Dictionary(grouping: daily) { calendar.dateInterval(of: component, for: $0.0)!.start }
            return groups.keys.sorted().map { key in
                let values = groups[key]!.map(\.1)
                return TrendPoint(date: key, value: values.reduce(0, +) / Double(values.count), rolling7: nil, count: values.count)
            }
        }
    }
}
