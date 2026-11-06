import Foundation

/// Decides when to send the "elevated at desk" nudge (spec F2.6). Pure logic,
/// no timers: it is fed every live sample and answers "fire now?".
///
/// Fires once when ALL hold:
/// - HR ≥ resting baseline + threshold, continuously for ≥ the sustained duration
///   (a sample below the threshold, or a gap > `maxGap`, restarts the clock)
/// - not in a workout session, inside work hours on a work day, outside quiet hours
/// - at least `minInterval` since the last nudge
public struct NudgeEngine: Sendable {
    public static let maxGap: TimeInterval = 120

    public private(set) var elevatedSince: Date?
    public private(set) var lastSampleAt: Date?
    public var lastNudgeAt: Date?

    public init(lastNudgeAt: Date? = nil) {
        self.lastNudgeAt = lastNudgeAt
    }

    public mutating func ingest(bpm: Int, at date: Date, restingHR: Int, inWorkout: Bool,
                                settings: AppSettings, calendar: Calendar = .current) -> Bool {
        defer { lastSampleAt = date }
        guard settings.nudgeEnabled, !inWorkout else {
            elevatedSince = nil
            return false
        }
        if let last = lastSampleAt, date.timeIntervalSince(last) > Self.maxGap {
            elevatedSince = nil
        }
        guard bpm >= restingHR + settings.nudgeThresholdBPM else {
            elevatedSince = nil
            return false
        }
        let since = elevatedSince ?? date
        elevatedSince = since

        let sustained = date.timeIntervalSince(since) >= TimeInterval(settings.nudgeSustainedMinutes * 60)
        let rateOK = lastNudgeAt.map { date.timeIntervalSince($0) >= TimeInterval(settings.nudgeMinIntervalMinutes * 60) } ?? true
        guard sustained, rateOK,
              settings.isWorkTime(date, calendar: calendar),
              !settings.quietHours.contains(date, calendar: calendar) else { return false }

        lastNudgeAt = date
        elevatedSince = nil
        return true
    }

    /// Calm, non-alarming wording (spec §4 health-safety).
    public static let title = "Time for a short break?"
    public static func body(minutes: Int) -> String {
        "Your heart rate has been higher than your usual resting level for about \(minutes) minutes while at your desk. A 2-minute breathing break or a short walk might help."
    }
}
