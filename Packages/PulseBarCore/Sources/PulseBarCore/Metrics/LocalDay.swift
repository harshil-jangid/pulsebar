import Foundation

/// "YYYY-MM-DD" strings for the user's local calendar day: the key used by
/// `daily_metrics`, check-ins and the MCP tools.
public enum LocalDay {
    public static func string(_ date: Date, _ calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func parse(_ s: String, _ calendar: Calendar = .current) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...12).contains(p[1]), (1...31).contains(p[2]) else { return nil }
        guard let d = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2])),
              string(d, calendar) == s else { return nil } // rejects 2026-02-31
        return d
    }

    public static func adding(_ days: Int, to s: String, _ calendar: Calendar = .current) -> String? {
        parse(s, calendar).flatMap { calendar.date(byAdding: .day, value: days, to: $0) }.map { string($0, calendar) }
    }
}
