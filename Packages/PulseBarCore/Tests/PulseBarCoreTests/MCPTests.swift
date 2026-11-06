import CryptoKit
import Foundation
import GRDB
import Testing
@testable import PulseBarCore

@MainActor
@Suite("MCP server")
final class MCPServerTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "pb-mcp-\(UUID().uuidString)")
    /// The file behind the most recent `makeServer()` (each server gets its own).
    var url: URL = URL(fileURLWithPath: "/dev/null")
    let fixedNow = utc.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 9))!

    deinit { try? FileManager.default.removeItem(at: dir) }

    /// Real on-disk database written by the app side, then opened read-only for the server.
    func makeServer(claudeAccess: Bool = true) throws -> MCPServer {
        url = dir.appending(path: "\(UUID().uuidString).sqlite")
        let db = try AppDatabase.openShared(at: url)
        try db.writer.write { d in
            for r in fixtureRows() {
                try d.execute(sql: "INSERT INTO daily_metrics (date, resting_hr, hrv_rmssd_ms, sleep_minutes, steps) VALUES (?,?,?,?,?)",
                              arguments: [r.date, r.restingHR, r.hrvMs, r.sleepMinutes, r.steps])
            }
        }
        try db.saveGoal(Goal(label: "Wedding", goalDate: "2027-02-12"))
        _ = try db.ensureStartSnapshot()
        var c = Checkin(nightOf: "2026-11-04"); c.alcohol = .some
        try db.saveCheckin(c)
        let rec = SessionRecorder(db: db)
        rec.record(HeartRateMeasurement(bpm: 72, sensorContact: .detected, rrIntervalsMs: [830]), at: fixedNow)
        rec.endSession(at: fixedNow.addingTimeInterval(600))
        let settings = SettingsStore(db: db)
        settings.update { $0.claudeAccessEnabled = claudeAccess }
        return MCPServer(reader: try AppDatabase.openReadOnly(at: url), calendar: utc, now: { [fixedNow] in fixedNow })
    }

    static let modernMeta: [String: Any] = [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": ["name": "test", "version": "1"],
        "io.modelcontextprotocol/clientCapabilities": [:],
    ]

    func send(_ server: MCPServer, _ method: String, _ params: [String: Any] = [:], modern: Bool = true, id: Int = 1) -> [String: Any] {
        var p = params
        if modern { p["_meta"] = Self.modernMeta }
        let line = MCPServer.encode(["jsonrpc": "2.0", "id": id, "method": method, "params": p])!
        let out = server.handle(line: line)!
        #expect(!out.contains("\n"), "stdio messages must be single-line")
        return try! JSONSerialization.jsonObject(with: Data(out.utf8)) as! [String: Any]
    }

    func call(_ server: MCPServer, _ name: String, _ args: [String: Any] = [:]) -> (structured: [String: Any]?, isError: Bool, text: String) {
        let r = send(server, "tools/call", ["name": name, "arguments": args])["result"] as! [String: Any]
        let text = ((r["content"] as! [[String: Any]]).first!["text"] as! String)
        return (r["structuredContent"] as? [String: Any], r["isError"] as! Bool, text)
    }

    // MARK: Protocol

    @Test("legacy initialize negotiates a supported version, then serves tools without _meta")
    func legacy() throws {
        let server = try makeServer()
        let initResult = send(server, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                      "clientInfo": ["name": "Claude", "version": "x"]], modern: false)["result"] as! [String: Any]
        #expect(initResult["protocolVersion"] as? String == "2025-06-18")
        #expect((initResult["serverInfo"] as? [String: Any])?["name"] as? String == "pulsebar-mcp")
        #expect(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let list = send(server, "tools/list", modern: false, id: 2)["result"] as! [String: Any]
        #expect((list["tools"] as! [Any]).count == 8)
        #expect(list["resultType"] == nil) // legacy results don't carry modern fields

        let unknown = try makeServer()
        let r = send(unknown, "initialize", ["protocolVersion": "1999-01-01"], modern: false)["result"] as! [String: Any]
        #expect(r["protocolVersion"] as? String == "2025-11-25")
    }

    @Test("modern: server/discover lists versions; results carry resultType and serverInfo")
    func modern() throws {
        let server = try makeServer()
        let r = send(server, "server/discover")["result"] as! [String: Any]
        #expect(r["resultType"] as? String == "complete")
        #expect((r["supportedVersions"] as! [String]).contains("2026-07-28"))
        #expect((r["supportedVersions"] as! [String]).contains("2025-11-25"))
        #expect(((r["_meta"] as! [String: Any])["io.modelcontextprotocol/serverInfo"] as! [String: Any])["name"] as? String == "pulsebar-mcp")
    }

    @Test("modern errors: unsupported version, missing capabilities, missing meta")
    func modernErrors() throws {
        let server = try makeServer()
        let bad = MCPServer.encode(["jsonrpc": "2.0", "id": 9, "method": "tools/list",
                                    "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "1900-01-01",
                                                         "io.modelcontextprotocol/clientCapabilities": [:]]]])!
        let e1 = try JSONSerialization.jsonObject(with: Data(server.handle(line: bad)!.utf8)) as! [String: Any]
        #expect((e1["error"] as! [String: Any])["code"] as? Int == -32022)
        #expect(((e1["error"] as! [String: Any])["data"] as! [String: Any])["requested"] as? String == "1900-01-01")

        let noCaps = MCPServer.encode(["jsonrpc": "2.0", "id": 10, "method": "tools/list",
                                       "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]])!
        let e2 = try JSONSerialization.jsonObject(with: Data(server.handle(line: noCaps)!.utf8)) as! [String: Any]
        #expect((e2["error"] as! [String: Any])["code"] as? Int == -32602)

        let e3 = send(server, "tools/list", modern: false)
        #expect((e3["error"] as! [String: Any])["code"] as? Int == -32602)
    }

    @Test("JSON-RPC errors: parse error, unknown method, unknown tool")
    func rpcErrors() throws {
        let server = try makeServer()
        let parse = try JSONSerialization.jsonObject(with: Data(server.handle(line: "{nope")!.utf8)) as! [String: Any]
        #expect((parse["error"] as! [String: Any])["code"] as? Int == -32700)
        #expect((send(server, "resources/list")["error"] as! [String: Any])["code"] as? Int == -32601)
        #expect((send(server, "tools/call", ["name": "delete_everything"])["error"] as! [String: Any])["code"] as? Int == -32602)
    }

    @Test("tool list matches the golden file and every tool is annotated read-only")
    func golden() throws {
        let server = try makeServer()
        let tools = (send(server, "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]]
        #expect(tools.map { $0["name"] as! String } == ["get_daily_metrics", "get_baselines", "get_readiness", "get_trends",
                                                        "get_goal_progress", "get_checkins", "get_habit_impact", "get_live_sessions"])
        for t in tools {
            let a = t["annotations"] as! [String: Any]
            #expect(a["readOnlyHint"] as? Bool == true)
            #expect(a["destructiveHint"] as? Bool == false)
            #expect((t["inputSchema"] as! [String: Any])["type"] as? String == "object")
        }
        let encoded = MCPServer.encode(tools)!
        let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Golden/tools-list.json")
        if ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: goldenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (encoded + "\n").write(to: goldenURL, atomically: true, encoding: .utf8)
        }
        let golden = try String(contentsOf: goldenURL, encoding: .utf8).trimmingCharacters(in: .newlines)
        #expect(encoded == golden, "tools/list changed — review, then regenerate with UPDATE_GOLDEN=1")
    }

    // MARK: Tools

    @Test("get_daily_metrics returns units, timezone and rows; validates input")
    func dailyMetrics() throws {
        let server = try makeServer()
        let r = call(server, "get_daily_metrics", ["start_date": "2026-11-01", "end_date": "2026-11-05"])
        #expect(!r.isError)
        #expect(r.structured?["timezone"] as? String == utc.timeZone.identifier)
        #expect((r.structured?["units"] as? [String: String])?["hrv_ms"] == "ms (RMSSD during sleep)")
        #expect((r.structured?["days"] as? [[String: Any]])?.count == 5)

        #expect(call(server, "get_daily_metrics", ["start_date": "2025-01-01", "end_date": "2026-11-05"]).isError)
        #expect(call(server, "get_daily_metrics", ["start_date": "11/01/2026", "end_date": "2026-11-05"]).isError)
        #expect(call(server, "get_daily_metrics", ["start_date": "2026-11-05", "end_date": "2026-11-01"]).isError)
    }

    @Test("get_readiness matches the app's computation, with why and a disclaimer")
    func readiness() throws {
        let r = call(try makeServer(), "get_readiness", ["date": "2026-11-05"])
        #expect(r.structured?["score"] as? Int == 60)
        #expect(r.structured?["band"] as? String == "Go hard")
        #expect((r.structured?["why"] as? [String])?.first == "HRV 14% above your baseline")
        #expect((r.structured?["note"] as? String)?.contains("not medical advice") == true)
    }

    @Test("baselines, trends, goal, check-ins, habits and sessions all answer")
    func others() throws {
        let server = try makeServer()
        let b = call(server, "get_baselines", ["as_of_date": "2026-11-05"])
        #expect(((b.structured?["baselines"] as? [[String: Any]])?.first { $0["metric"] as? String == "hrv" })?["median"] as? Double == 42)
        let t = call(server, "get_trends", ["metric": "steps", "period": "week", "since_date": "2026-10-01"])
        #expect(!t.isError)
        #expect(call(server, "get_trends", ["metric": "steps", "period": "day", "since_date": "2026-10-01"]).isError)
        let g = call(server, "get_goal_progress")
        #expect(g.structured?["days_remaining"] as? Int == 99)
        let c = call(server, "get_checkins", ["start_date": "2026-11-01", "end_date": "2026-11-05"])
        #expect((c.structured?["checkins"] as? [[String: Any]])?.first?["alcohol"] as? String == "some")
        let h = call(server, "get_habit_impact", ["metric": "hrv"])
        #expect(!h.isError)
        #expect((h.structured?["note"] as? String)?.contains("not evidence of cause") == true)
        let s = call(server, "get_live_sessions", ["start_date": "2026-11-05", "end_date": "2026-11-05"])
        let session = (s.structured?["sessions"] as? [[String: Any]])?.first
        #expect(session?["max_hr"] as? Int == 72)
        #expect(session?["samples"] == nil) // summaries only
    }

    @Test("Claude access off → tools refuse with a clear message")
    func accessGate() throws {
        let r = call(try makeServer(claudeAccess: false), "get_readiness", ["date": "2026-11-05"])
        #expect(r.isError)
        #expect(r.text.contains("Settings → Claude"))
    }

    @Test("missing database → friendly tool error, protocol still works")
    func noDatabase() {
        let server = MCPServer(reader: nil, calendar: utc)
        #expect((send(server, "tools/list")["result"] as? [String: Any]) != nil)
        #expect(call(server, "get_goal_progress").text.contains("Open PulseBar"))
    }

    // MARK: Read-only guarantee (F8.1, M6 acceptance)

    @Test("the server cannot write: database bytes unchanged after every tool; writes are rejected by SQLite")
    func cannotWrite() throws {
        let server = try makeServer()
        let before = SHA256.hash(data: try Data(contentsOf: url))
        let calls: [(String, [String: Any])] = [
            ("get_daily_metrics", ["start_date": "2026-10-01", "end_date": "2026-11-05"]),
            ("get_baselines", ["as_of_date": "2026-11-05"]), ("get_readiness", ["date": "2026-11-05"]),
            ("get_trends", ["metric": "hrv", "period": "month", "since_date": "2026-01-01"]),
            ("get_goal_progress", [:]), ("get_checkins", ["start_date": "2026-11-01", "end_date": "2026-11-05"]),
            ("get_habit_impact", ["metric": "resting_hr"]), ("get_live_sessions", ["start_date": "2026-11-01", "end_date": "2026-11-05"]),
        ]
        for (name, args) in calls { #expect(!call(server, name, args).isError, "\(name)") }
        #expect(SHA256.hash(data: try Data(contentsOf: url)) == before)

        let reader = try AppDatabase.openReadOnly(at: url) as! DatabaseQueue
        #expect(throws: DatabaseError.self) {
            try reader.write { try $0.execute(sql: "DELETE FROM daily_metrics") }
        }
    }
}
