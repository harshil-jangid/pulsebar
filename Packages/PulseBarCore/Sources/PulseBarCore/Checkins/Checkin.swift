import Foundation
import GRDB

/// One evening check-in (F6.1). Stored as one row per tag in `checkins`
/// (`night_of`, `tag`, `value`), so custom tags need no schema change.
public struct Checkin: Sendable, Equatable, Codable {
    public enum Alcohol: String, CaseIterable, Sendable, Codable { case none, some, aLot = "a_lot" }
    public enum Workout: String, CaseIterable, Sendable, Codable { case none, easy, moderate, hard }
    public enum Location: String, CaseIterable, Sendable, Codable { case office, home }

    /// The night this check-in describes (YYYY-MM-DD). Compared with the NEXT morning's data (F6.3).
    public var nightOf: String
    public var alcohol: Alcohol = .none
    public var lateHeavyMeal = false
    public var caffeineAfter3pm = false
    public var workout: Workout = .none
    public var workoutType: String?
    public var location: Location = .office
    public var lateScreens = false
    /// 1 (calm) … 5 (very stressed).
    public var stress = 2
    public var note: String?
    /// Custom yes/no tags (F6.2), keyed by tag id.
    public var custom: [String: Bool] = [:]

    public init(nightOf: String) { self.nightOf = nightOf }

    /// Check-ins made after midnight but before 4 am still describe the previous night.
    public static func nightOf(_ date: Date, calendar: Calendar = .current) -> String {
        let shifted = calendar.component(.hour, from: date) < 4 ? calendar.date(byAdding: .day, value: -1, to: date)! : date
        return LocalDay.string(shifted, calendar)
    }

    /// The morning whose HRV / resting HR follows this night.
    public var nextMorning: String { LocalDay.adding(1, to: nightOf) ?? nightOf }

    // MARK: Row mapping

    var rows: [(String, String)] {
        var r: [(String, String)] = [
            ("alcohol", alcohol.rawValue), ("late_meal", String(lateHeavyMeal)),
            ("caffeine_after_3pm", String(caffeineAfter3pm)), ("workout", workout.rawValue),
            ("location", location.rawValue), ("late_screens", String(lateScreens)), ("stress", String(stress)),
        ]
        if let workoutType, !workoutType.isEmpty { r.append(("workout_type", workoutType)) }
        if let note, !note.isEmpty { r.append(("note", note)) }
        for (k, v) in custom { r.append(("custom:\(k)", String(v))) }
        return r
    }

    init(nightOf: String, rows: [(String, String)]) {
        self.nightOf = nightOf
        for (tag, value) in rows {
            switch tag {
            case "alcohol": alcohol = Alcohol(rawValue: value) ?? .none
            case "late_meal": lateHeavyMeal = value == "true"
            case "caffeine_after_3pm": caffeineAfter3pm = value == "true"
            case "workout": workout = Workout(rawValue: value) ?? .none
            case "workout_type": workoutType = value
            case "location": location = Location(rawValue: value) ?? .office
            case "late_screens": lateScreens = value == "true"
            case "stress": stress = Int(value) ?? 2
            case "note": note = value
            case let t where t.hasPrefix("custom:"): custom[String(t.dropFirst(7))] = value == "true"
            default: break
            }
        }
    }
}

/// A user-defined yes/no tag (F6.2).
public struct CustomTag: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var hidden: Bool

    public init(name: String) {
        id = UUID().uuidString
        self.name = name
        hidden = false
    }
}

extension Checkin {
    /// Usable from any database connection, including the MCP server's read-only one.
    static func fetch(_ db: Database, from: String, to: String) throws -> [Checkin] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT night_of, tag, value FROM checkins WHERE night_of >= ? AND night_of < ? ORDER BY night_of
            """, arguments: [from, to])
        let grouped = Dictionary(grouping: rows) { $0["night_of"] as String }
        return grouped.keys.sorted().map { night in
            Checkin(nightOf: night, rows: grouped[night]!.map { ($0["tag"], $0["value"]) })
        }
    }
}

extension AppDatabase {
    /// Replaces the check-in for that night (saving twice doesn't duplicate).
    public func saveCheckin(_ c: Checkin, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM checkins WHERE night_of = ?", arguments: [c.nightOf])
            let stmt = try db.makeStatement(sql: "INSERT INTO checkins (night_of, tag, value, created_at) VALUES (?, ?, ?, ?)")
            for (tag, value) in c.rows { try stmt.execute(arguments: [c.nightOf, tag, value, now]) }
        }
    }

    public func checkins(from: String, to: String) throws -> [Checkin] {
        try writer.read { try Checkin.fetch($0, from: from, to: to) }
    }

    public func checkin(nightOf: String) throws -> Checkin? {
        try checkins(from: nightOf, to: LocalDay.adding(1, to: nightOf) ?? nightOf).first
    }

    public func latestCheckin() throws -> Checkin? {
        guard let night = try writer.read({ try String.fetchOne($0, sql: "SELECT MAX(night_of) FROM checkins") }) else { return nil }
        return try checkin(nightOf: night)
    }
}
