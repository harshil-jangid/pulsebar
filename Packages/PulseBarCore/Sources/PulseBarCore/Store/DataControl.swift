import Foundation
import GRDB

/// Export, delete and retention (F9).
extension AppDatabase {
    /// Tables included in exports and wiped by "Delete all data".
    public static let dataTables = ["daily_metrics", "workouts", "live_sessions", "live_samples", "live_rr",
                                    "checkins", "goal", "sync_state", "settings"]

    /// Writes one CSV per table plus `pulsebar.json` (all tables) into `directory`. Returns the files written.
    @discardableResult
    public func export(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [URL] = []
        var json: [String: Any] = ["exported_at": ISO8601DateFormatter().string(from: Date()),
                                   "app_version": PulseBarCore.version]
        try writer.read { db in
            for table in Self.dataTables {
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table)")
                let columns = try db.columns(in: table).map(\.name)
                var csv = columns.map(Self.csvField).joined(separator: ",") + "\n"
                var jsonRows: [[String: Any]] = []
                for row in rows {
                    var obj: [String: Any] = [:]
                    let fields = columns.map { col -> String in
                        let value = row[col] as DatabaseValue
                        let text = Self.text(value)
                        obj[col] = text.map { $0 as Any } ?? NSNull()
                        return Self.csvField(text ?? "")
                    }
                    csv += fields.joined(separator: ",") + "\n"
                    jsonRows.append(obj)
                }
                // Never export secrets: the settings JSON holds no tokens (those live in the Keychain).
                let url = directory.appending(path: "\(table).csv")
                try csv.write(to: url, atomically: true, encoding: .utf8)
                files.append(url)
                json[table] = jsonRows
            }
        }
        let jsonURL = directory.appending(path: "pulsebar.json")
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: jsonURL)
        files.append(jsonURL)
        return files
    }

    /// Deletes every row in every table (schema stays, so the app keeps working). F9.2.
    public func deleteAllData() throws {
        try writer.write { db in
            for table in Self.dataTables.reversed() { try db.execute(sql: "DELETE FROM \(table)") }
        }
        try writer.vacuum() // actually shrink the file so deleted data doesn't linger on disk
    }

    /// Keeps per-session summaries but removes raw live samples/RR older than `days` (F9.3).
    @discardableResult
    public func pruneLiveSamples(olderThan days: Int = 90, now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return try writer.write { db in
            let old = "SELECT id FROM live_sessions WHERE start < ? AND end IS NOT NULL"
            try db.execute(sql: "DELETE FROM live_samples WHERE session_id IN (\(old))", arguments: [cutoff])
            let n = db.changesCount
            try db.execute(sql: "DELETE FROM live_rr WHERE session_id IN (\(old))", arguments: [cutoff])
            return n
        }
    }

    static func text(_ v: DatabaseValue) -> String? {
        switch v.storage {
        case .null: nil
        case .int64(let i): String(i)
        case .double(let d): String(d)
        case .string(let s): s
        case .blob(let b): b.base64EncodedString()
        }
    }

    static func csvField(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}

/// Checks GitHub Releases for a newer version (F10.1). At most daily, can be
/// disabled, sends no identifiers. Never downloads or installs anything.
public enum UpdateCheck {
    public static let latestURL = URL(string: "https://api.github.com/repos/harshil-jangid/pulsebar/releases/latest")!

    public struct Release: Sendable, Equatable {
        public let version: String
        public let url: URL
    }

    public static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        lastCheck.map { now.timeIntervalSince($0) >= 86_400 } ?? true
    }

    /// Returns the release if it's newer than `current`.
    public static func newer(than current: String, transport: HTTPTransport) async throws -> Release? {
        var req = URLRequest(url: latestURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PulseBar", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.send(req)
        guard response.statusCode == 200 else { return nil } // 404 = no releases yet
        return try parse(data, current: current)
    }

    static func parse(_ data: Data, current: String) throws -> Release? {
        struct R: Decodable { let tag_name: String; let html_url: URL; let draft: Bool?; let prerelease: Bool? }
        let r = try JSONDecoder().decode(R.self, from: data)
        guard r.draft != true, r.prerelease != true else { return nil }
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        return compare(version, current) > 0 ? Release(version: version, url: r.html_url) : nil
    }

    /// Numeric semantic-version comparison ("1.10.0" > "1.9.2").
    public static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}
