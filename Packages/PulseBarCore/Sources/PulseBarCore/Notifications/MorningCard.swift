import Foundation

/// The morning readiness notification (F4.3): sent once per day, at or after
/// the chosen time, only once today's data has synced, never in quiet hours.
public enum MorningCard {
    public static func message(now: Date, settings: AppSettings, readiness: Readiness,
                               calendar: Calendar = .current) -> (title: String, body: String)? {
        let today = LocalDay.string(now, calendar)
        guard settings.morningReadinessEnabled,
              settings.lastMorningNotificationDay != today,
              readiness.date == today,
              readiness.state == .ready, let band = readiness.band,
              !settings.quietHours.contains(now, calendar: calendar) else { return nil }
        let c = calendar.dateComponents([.hour, .minute], from: now)
        guard (c.hour ?? 0) * 60 + (c.minute ?? 0) >= settings.morningReadinessMinute else { return nil }
        let reason = readiness.reasons.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
        return ("Today: \(band.rawValue)", reason)
    }
}
