import Foundation

/// Deterministic sample history for demo mode (`-demo`) and screenshots.
/// Only ever written to the in-memory demo database.
public enum DemoData {
    /// 60 days ending yesterday, with gentle improvement (HRV up, RHR down) and weekly rhythm.
    public static func rows(endingBefore today: String = LocalDay.string(Date()), days: Int = 60) -> [DailyMetric] {
        (1...days).reversed().compactMap { i -> DailyMetric? in
            guard let day = LocalDay.adding(-i, to: today) else { return nil }
            let progress = Double(days - i) / Double(days)          // 0 → 1 over the period
            let wobble = sin(Double(i) * 1.3)
            let weekend = i % 7 < 2
            return DailyMetric(date: day,
                               restingHR: (64 - 4 * progress + wobble * 1.5).rounded(),
                               hrvMs: ((36 + 8 * progress + wobble * 4) * 10).rounded() / 10,
                               sleepMinutes: Int(400 + wobble * 30 + (weekend ? 35 : 0)),
                               steps: Int(5500 + progress * 2500 + wobble * 1500 + (weekend ? 2500 : 0)))
        }
    }

    public static func seed(_ db: AppDatabase) {
        let today = LocalDay.string(Date())
        var rows = rows(endingBefore: today)
        rows.append(DailyMetric(date: today, restingHR: 59, hrvMs: 47, sleepMinutes: 435, steps: 3100))
        try? db.writer.write { d in
            for r in rows {
                try d.execute(sql: """
                    INSERT OR REPLACE INTO daily_metrics (date, resting_hr, hrv_rmssd_ms, sleep_minutes, steps, source)
                    VALUES (?, ?, ?, ?, ?, 'demo')
                    """, arguments: [r.date, r.restingHR, r.hrvMs, r.sleepMinutes, r.steps])
            }
        }
        let goalDay = LocalDay.adding(100, to: today) ?? today
        try? db.saveGoal(Goal(label: "Wedding", goalDate: goalDay))
    }
}
