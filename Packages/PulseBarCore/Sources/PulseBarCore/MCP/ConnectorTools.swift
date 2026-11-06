import Foundation
import GRDB

struct ToolError: Error {
    let message: String
}

/// The eight read-only tools from SPEC F8.2. Every response states the time zone
/// and units. Ranges are capped at 366 days (F8.3).
struct ConnectorTools {
    static let maxDays = 366

    let reader: (any DatabaseReader)?
    let calendar: Calendar
    let now: @Sendable () -> Date

    static let names: Set<String> = Set(definitions.compactMap { $0["name"] as? String })

    static var readOnly: [String: Any] {
        ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
    }

    static func dateParam(_ description: String) -> [String: Any] {
        ["type": "string", "pattern": "^\\d{4}-\\d{2}-\\d{2}$", "description": description]
    }

    static var rangeSchema: [String: Any] { [
        "type": "object",
        "properties": ["start_date": dateParam("First day, YYYY-MM-DD (local)"),
                       "end_date": dateParam("Last day, inclusive, YYYY-MM-DD (local). Max 366 days after start_date.")],
        "required": ["start_date", "end_date"], "additionalProperties": false,
    ] }

    static var definitions: [[String: Any]] { [
        tool("get_daily_metrics", "Daily metrics",
             "Daily resting heart rate, sleep HRV (RMSSD), sleep duration and stages, steps, SpO2, breathing rate and VO2 max from Google Health.",
             rangeSchema),
        tool("get_baselines", "Personal baselines",
             "30-day personal baselines (median and MAD) before a date for resting HR, sleep HRV, sleep and steps, and whether each is calibrated (≥14 days).",
             ["type": "object", "properties": ["as_of_date": dateParam("Baselines use the 30 days before this date")],
              "required": ["as_of_date"], "additionalProperties": false]),
        tool("get_readiness", "Readiness",
             "Readiness score (0–100), band (Go hard / Normal day / Take it easy) and the per-metric 'why' for a day. A personal heuristic, not medical advice.",
             ["type": "object", "properties": ["date": dateParam("Day to score")], "required": ["date"], "additionalProperties": false]),
        tool("get_trends", "Trends",
             "Weekly or monthly averages of a metric since a date.",
             ["type": "object",
              "properties": ["metric": ["type": "string", "enum": Metric.allCases.map(\.rawValue)],
                             "period": ["type": "string", "enum": ["week", "month"]],
                             "since_date": dateParam("First day to include (max 366 days ago)")],
              "required": ["metric", "period", "since_date"], "additionalProperties": false]),
        tool("get_goal_progress", "Goal progress",
             "The user's goal and date, days remaining, starting baseline (first 14 calibrated days) and recent values.",
             ["type": "object", "additionalProperties": false]),
        tool("get_checkins", "Check-ins",
             "Evening check-ins (alcohol, late meal, caffeine after 3 pm, workout, work location, late screens, stress 1–5, note). Each describes the night that follows that date.",
             rangeSchema),
        tool("get_habit_impact", "Habit associations",
             "How next-morning HRV or resting HR differed on nights with vs without each habit. Shown only with ≥5 nights per group. Associations, not causes.",
             ["type": "object", "properties": ["metric": ["type": "string", "enum": ["hrv", "resting_hr"]]],
              "required": ["metric"], "additionalProperties": false]),
        tool("get_live_sessions", "Live sessions",
             "Summaries of live heart-rate sessions (desk or workout): start, end, average and max HR, live RMSSD. No raw samples. Live HRV is not comparable to sleep HRV.",
             rangeSchema),
    ] }

    static func tool(_ name: String, _ title: String, _ description: String, _ schema: [String: Any]) -> [String: Any] {
        ["name": name, "title": title, "description": description, "inputSchema": schema, "annotations": readOnly]
    }

    // MARK: Dispatch

    func call(_ name: String, _ args: [String: Any]) -> Result<[String: Any], ToolError> {
        guard let reader else {
            return .failure(ToolError(message: "PulseBar's database wasn't found. Open PulseBar on this Mac first."))
        }
        do {
            let settings = try reader.read { db -> AppSettings in
                let json = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [AppSettings.storageKey])
                return json.flatMap { try? JSONDecoder().decode(AppSettings.self, from: Data($0.utf8)) } ?? AppSettings()
            }
            guard settings.claudeAccessEnabled else {
                return .failure(ToolError(message: "Claude access is turned off. The user can allow it in PulseBar → Settings → Claude."))
            }
            switch name {
            case "get_daily_metrics": return .success(try dailyMetrics(args))
            case "get_baselines": return .success(try baselines(args))
            case "get_readiness": return .success(try readiness(args))
            case "get_trends": return .success(try trends(args))
            case "get_goal_progress": return .success(try goalProgress())
            case "get_checkins": return .success(try checkins(args))
            case "get_habit_impact": return .success(try habitImpact(args, settings: settings))
            case "get_live_sessions": return .success(try liveSessions(args))
            default: return .failure(ToolError(message: "Unknown tool \(name)"))
            }
        } catch let e as ToolError {
            return .failure(e)
        } catch {
            return .failure(ToolError(message: "Couldn't read PulseBar data: \(error.localizedDescription)"))
        }
    }

    // MARK: Argument validation

    func date(_ args: [String: Any], _ key: String) throws -> String {
        guard let s = args[key] as? String, LocalDay.parse(s, calendar) != nil else {
            throw ToolError(message: "\(key) must be a date in YYYY-MM-DD format.")
        }
        return s
    }

    /// Returns [start, endExclusive).
    func range(_ args: [String: Any]) throws -> (String, String) {
        let start = try date(args, "start_date"), end = try date(args, "end_date")
        guard start <= end else { throw ToolError(message: "start_date must be on or before end_date.") }
        let days = calendar.dateComponents([.day], from: LocalDay.parse(start, calendar)!, to: LocalDay.parse(end, calendar)!).day ?? 0
        guard days < Self.maxDays else { throw ToolError(message: "Range too long: at most \(Self.maxDays) days per call.") }
        return (start, LocalDay.adding(1, to: end, calendar)!)
    }

    var context: [String: Any] { ["timezone": calendar.timeZone.identifier] }

    static let metricUnits: [String: String] = [
        "resting_hr": "bpm", "hrv_ms": "ms (RMSSD during sleep)", "sleep_minutes": "minutes",
        "deep_min": "minutes", "rem_min": "minutes", "light_min": "minutes", "awake_min": "minutes",
        "steps": "steps", "spo2_avg": "%", "resp_rate": "breaths/min", "vo2max": "ml/kg/min",
    ]

    func rows(_ db: Database, from: String = "0000-01-01", to: String = "9999-12-31") throws -> [DailyMetric] {
        try DailyMetric.filter(Column("date") >= from && Column("date") < to).order(Column("date")).fetchAll(db)
    }

    // MARK: Tools

    func dailyMetrics(_ args: [String: Any]) throws -> [String: Any] {
        let (from, to) = try range(args)
        let list = try reader!.read { try rows($0, from: from, to: to) }
        var out = context
        out["units"] = Self.metricUnits
        out["days"] = list.map { r -> [String: Any] in
            var d: [String: Any] = ["date": r.date]
            d["resting_hr"] = r.restingHR
            d["hrv_ms"] = r.hrvMs
            d["sleep_minutes"] = r.sleepMinutes
            d["deep_min"] = r.deepMin
            d["rem_min"] = r.remMin
            d["light_min"] = r.lightMin
            d["awake_min"] = r.awakeMin
            d["steps"] = r.steps
            d["spo2_avg"] = r.spo2
            d["resp_rate"] = r.respRate
            d["vo2max"] = r.vo2max
            return d
        }
        return out
    }

    func baselines(_ args: [String: Any]) throws -> [String: Any] {
        let asOf = try date(args, "as_of_date")
        let all = try reader!.read { try rows($0) }
        var out = context
        out["as_of_date"] = asOf
        out["window_days"] = Baseline.windowDays
        out["minimum_days_for_calibration"] = Baseline.minimumDays
        out["baselines"] = Metric.allCases.map { m -> [String: Any] in
            var b: [String: Any] = ["metric": m.rawValue, "unit": m.unit]
            if let base = Baseline.compute(m, before: asOf, in: all, calendar: calendar) {
                b["median"] = base.median
                b["mad"] = base.mad
                b["valid_days"] = base.validDays
                b["calibrated"] = base.isCalibrated
            } else {
                b["valid_days"] = 0
                b["calibrated"] = false
            }
            return b
        }
        return out
    }

    func readiness(_ args: [String: Any]) throws -> [String: Any] {
        let day = try date(args, "date")
        let all = try reader!.read { try rows($0) }
        let r = Readiness.compute(date: day, rows: all, calendar: calendar)
        var out = context
        out["date"] = day
        switch r.state {
        case .calibrating(let n): out["state"] = "calibrating"; out["calibrated_days"] = n
        case .noData: out["state"] = "no_data"
        case .ready: out["state"] = "ready"
        }
        out["score"] = r.score
        out["band"] = r.band?.rawValue
        out["why"] = r.reasons
        out["components"] = r.components.map {
            ["metric": $0.metric.rawValue, "unit": $0.metric.unit, "today": $0.today,
             "baseline_median": $0.baseline, "robust_z_good_direction": $0.z]
        }
        out["note"] = "Readiness is a tunable personal heuristic (not clinically validated), not medical advice."
        return out
    }

    func trends(_ args: [String: Any]) throws -> [String: Any] {
        guard let metric = (args["metric"] as? String).flatMap(Metric.init(rawValue:)) else {
            throw ToolError(message: "metric must be one of \(Metric.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard let period = (args["period"] as? String).flatMap(TrendPeriod.init(rawValue:)), period != .day else {
            throw ToolError(message: "period must be \"week\" or \"month\".")
        }
        let since = try date(args, "since_date")
        let today = LocalDay.string(now(), calendar)
        let days = calendar.dateComponents([.day], from: LocalDay.parse(since, calendar)!, to: LocalDay.parse(today, calendar)!).day ?? 0
        guard days < Self.maxDays else { throw ToolError(message: "since_date can be at most \(Self.maxDays) days ago.") }
        let list = try reader!.read { try rows($0, from: since) }
        var out = context
        out["metric"] = metric.rawValue
        out["unit"] = metric.unit
        out["period"] = period.rawValue
        out["points"] = Trends.series(metric, rows: list, period: period, calendar: calendar).map {
            ["period_start": LocalDay.string($0.date, calendar), "mean": $0.value, "days_with_data": $0.count]
        }
        return out
    }

    func goalProgress() throws -> [String: Any] {
        let (goal, all) = try reader!.read { (try Goal.fetch($0), try rows($0)) }
        var out = context
        guard let goal else {
            out["goal"] = NSNull()
            out["note"] = "No goal set. The user can set one in PulseBar → Settings → Goal."
            return out
        }
        let today = LocalDay.string(now(), calendar)
        out["goal"] = ["label": goal.label, "date": goal.goalDate, "intentions": goal.intentions as Any]
        out["today"] = today
        out["days_remaining"] = goal.daysRemaining(from: today, calendar: calendar)
        let recent = all.suffix(7)
        out["metrics"] = Metric.allCases.map { m -> [String: Any] in
            var d: [String: Any] = ["metric": m.rawValue, "unit": m.unit]
            d["start_baseline"] = goal.startSnapshot?.values[m]
            let latest = RobustStats.median(recent.compactMap { $0.value(m) })
            d["last_7_days_median"] = latest
            if let s = goal.startSnapshot?.values[m], let l = latest { d["change_since_start"] = l - s }
            return d
        }
        if let snap = goal.startSnapshot { out["start_period"] = ["from": snap.fromDate, "to": snap.toDate] }
        else { out["note"] = "Starting baseline is set after 14 days of data." }
        return out
    }

    func checkins(_ args: [String: Any]) throws -> [String: Any] {
        let (from, to) = try range(args)
        let list = try reader!.read { try Checkin.fetch($0, from: from, to: to) }
        var out = context
        out["attribution"] = "Each check-in describes the night that follows night_of; compare with the next morning's metrics."
        out["checkins"] = list.map { c -> [String: Any] in
            var d: [String: Any] = [
                "night_of": c.nightOf, "next_morning": c.nextMorning, "alcohol": c.alcohol.rawValue,
                "late_heavy_meal": c.lateHeavyMeal, "caffeine_after_3pm": c.caffeineAfter3pm,
                "workout": c.workout.rawValue, "work_location": c.location.rawValue,
                "late_screens": c.lateScreens, "stress_1_to_5": c.stress,
            ]
            d["workout_type"] = c.workoutType
            d["note"] = c.note
            return d
        }
        return out
    }

    func habitImpact(_ args: [String: Any], settings: AppSettings) throws -> [String: Any] {
        guard let raw = args["metric"] as? String, raw == "hrv" || raw == "resting_hr",
              let metric = Metric(rawValue: raw) else {
            throw ToolError(message: "metric must be \"hrv\" or \"resting_hr\".")
        }
        let (all, cks) = try reader!.read { (try rows($0), try Checkin.fetch($0, from: "0000-01-01", to: "9999-12-31")) }
        let insights = HabitInsights.compute(metric: metric, checkins: cks, rows: all,
                                             conditions: HabitCondition.builtIn(customTags: settings.customTags),
                                             calendar: calendar)
        var out = context
        out["metric"] = metric.rawValue
        out["unit"] = metric.unit
        out["minimum_nights_per_group"] = HabitInsights.minimumPerGroup
        out["insights"] = insights.map {
            ["habit": $0.conditionID, "summary": $0.sentence, "nights_with": $0.withCount, "nights_without": $0.withoutCount,
             "difference": $0.rawDifference, "difference_percent": $0.percentDifference,
             "z_difference": $0.zDifference, "confidence": $0.confidence.rawValue]
        }
        out["note"] = "Associations in the user's own data, not evidence of cause."
        return out
    }

    func liveSessions(_ args: [String: Any]) throws -> [String: Any] {
        let (from, to) = try range(args)
        guard let start = LocalDay.parse(from, calendar), let end = LocalDay.parse(to, calendar) else {
            throw ToolError(message: "Invalid date range.")
        }
        let list = try reader!.read {
            try LiveSession.filter(Column("start") >= start && Column("start") < end).order(Column("start")).fetchAll($0)
        }
        let iso = ISO8601DateFormatter()
        iso.timeZone = calendar.timeZone
        iso.formatOptions = [.withInternetDateTime]
        var out = context
        out["units"] = ["avg_hr": "bpm", "max_hr": "bpm", "duration_minutes": "minutes",
                        "live_rmssd_ms": "ms (live, awake; not comparable to sleep HRV)"]
        out["sessions"] = list.map { s -> [String: Any] in
            var d: [String: Any] = ["kind": s.kind.rawValue, "start": iso.string(from: s.start)]
            if let e = s.end { d["end"] = iso.string(from: e) }
            if let dur = s.duration { d["duration_minutes"] = Int((dur / 60).rounded()) }
            d["avg_hr"] = s.avgHR.map { ($0 * 10).rounded() / 10 }
            d["max_hr"] = s.maxHR
            d["live_rmssd_ms"] = s.liveRMSSDms.map { ($0 * 10).rounded() / 10 }
            d["device"] = s.deviceName
            return d
        }
        return out
    }
}
