import Foundation
import Observation

/// A daily time window in minutes since local midnight. May wrap past
/// midnight (e.g. quiet hours 22:00–07:00).
public struct DailyWindow: Codable, Sendable, Equatable {
    public var startMinute: Int
    public var endMinute: Int

    public init(start: Int, end: Int) {
        startMinute = start
        endMinute = end
    }

    public init(startHour: Int, endHour: Int) {
        self.init(start: startHour * 60, end: endHour * 60)
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if startMinute == endMinute { return false }
        if startMinute < endMinute { return m >= startMinute && m < endMinute }
        return m >= startMinute || m < endMinute // wraps midnight
    }
}

/// Everything the user can configure. Stored as one JSON document in the
/// `settings` table under `AppSettings.storageKey`. New fields must have
/// defaults so older saved JSON keeps decoding.
public struct AppSettings: Codable, Sendable, Equatable {
    public static let storageKey = "app_settings"

    // Onboarding & sources (F1.1)
    public var onboardingCompleted = false
    public var useGoogleHealth = false

    // Zones (F2.7)
    public var age: Int?
    public var maxHROverride: Int?
    public var rememberedDeviceID: UUID?

    // Work / quiet hours (F1.3)
    public var workHours = DailyWindow(startHour: 9, endHour: 18)
    /// Calendar weekday numbers, 1 = Sunday … 7 = Saturday.
    public var workDays: Set<Int> = [2, 3, 4, 5, 6]
    public var quietHours = DailyWindow(startHour: 22, endHour: 7)

    // Elevated-at-desk nudge (F2.6)
    public var nudgeEnabled = true
    public var nudgeThresholdBPM = 25
    public var nudgeSustainedMinutes = 10
    public var nudgeMinIntervalMinutes = 60
    /// Used until a resting-HR baseline exists.
    public var fallbackRestingHR = 65

    // Notifications (F4.3, F6.1)
    public var morningReadinessEnabled = true
    public var morningReadinessMinute = 8 * 60
    public var checkinReminderEnabled = true
    public var checkinReminderMinute = 21 * 60

    // Check-in custom tags (F6.2)
    public var customTags: [CustomTag] = []

    // Google (F3.1) — client ID is not secret; the secret and tokens live in the Keychain.
    public var googleClientID: String?

    // Claude connector (F8): Claude may read data only after the user opts in
    // (Google Health data policy: transfers only for a visible feature, with consent).
    public var claudeAccessEnabled = false

    // Updates (F10.1)
    public var updateCheckEnabled = true
    public var lastUpdateCheck: Date?

    // Internal bookkeeping
    public var lastNudgeAt: Date?
    public var lastMorningNotificationDay: String?

    public init() {}

    public var zones: HeartRateZones? {
        if let maxHROverride { return HeartRateZones(maxHR: maxHROverride) }
        return age.flatMap { HeartRateZones(age: $0) }
    }

    public func isWorkTime(_ date: Date, calendar: Calendar = .current) -> Bool {
        workDays.contains(calendar.component(.weekday, from: date)) && workHours.contains(date, calendar: calendar)
    }

    // Tolerant decoding: missing keys fall back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? fallback }
        onboardingCompleted = v(.onboardingCompleted, d.onboardingCompleted)
        useGoogleHealth = v(.useGoogleHealth, d.useGoogleHealth)
        age = try? c.decodeIfPresent(Int.self, forKey: .age)
        maxHROverride = try? c.decodeIfPresent(Int.self, forKey: .maxHROverride)
        rememberedDeviceID = try? c.decodeIfPresent(UUID.self, forKey: .rememberedDeviceID)
        workHours = v(.workHours, d.workHours)
        workDays = v(.workDays, d.workDays)
        quietHours = v(.quietHours, d.quietHours)
        nudgeEnabled = v(.nudgeEnabled, d.nudgeEnabled)
        nudgeThresholdBPM = v(.nudgeThresholdBPM, d.nudgeThresholdBPM)
        nudgeSustainedMinutes = v(.nudgeSustainedMinutes, d.nudgeSustainedMinutes)
        nudgeMinIntervalMinutes = v(.nudgeMinIntervalMinutes, d.nudgeMinIntervalMinutes)
        fallbackRestingHR = v(.fallbackRestingHR, d.fallbackRestingHR)
        morningReadinessEnabled = v(.morningReadinessEnabled, d.morningReadinessEnabled)
        morningReadinessMinute = v(.morningReadinessMinute, d.morningReadinessMinute)
        checkinReminderEnabled = v(.checkinReminderEnabled, d.checkinReminderEnabled)
        checkinReminderMinute = v(.checkinReminderMinute, d.checkinReminderMinute)
        customTags = v(.customTags, d.customTags)
        googleClientID = try? c.decodeIfPresent(String.self, forKey: .googleClientID)
        claudeAccessEnabled = v(.claudeAccessEnabled, d.claudeAccessEnabled)
        updateCheckEnabled = v(.updateCheckEnabled, d.updateCheckEnabled)
        lastUpdateCheck = try? c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
        lastNudgeAt = try? c.decodeIfPresent(Date.self, forKey: .lastNudgeAt)
        lastMorningNotificationDay = try? c.decodeIfPresent(String.self, forKey: .lastMorningNotificationDay)
    }
}

/// Remembers which Bluetooth device to reconnect to.
@MainActor
public protocol DeviceMemory: AnyObject {
    var rememberedDeviceID: UUID? { get set }
}

/// Observable, persisted settings. Every change is saved immediately.
@MainActor
@Observable
public final class SettingsStore: DeviceMemory {
    public private(set) var value: AppSettings
    @ObservationIgnored private let db: AppDatabase

    public init(db: AppDatabase) {
        self.db = db
        let json = (try? db.setting(AppSettings.storageKey)) ?? nil
        value = json.flatMap { try? JSONDecoder().decode(AppSettings.self, from: Data($0.utf8)) } ?? AppSettings()
    }

    /// Re-reads from the database (after "Delete all data").
    public func reload() {
        let json = (try? db.setting(AppSettings.storageKey)) ?? nil
        value = json.flatMap { try? JSONDecoder().decode(AppSettings.self, from: Data($0.utf8)) } ?? AppSettings()
    }

    public func update(_ change: (inout AppSettings) -> Void) {
        var copy = value
        change(&copy)
        guard copy != value else { return }
        value = copy
        save()
    }

    public var rememberedDeviceID: UUID? {
        get { value.rememberedDeviceID }
        set { update { $0.rememberedDeviceID = newValue } }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? db.setSetting(AppSettings.storageKey, String(decoding: data, as: UTF8.self))
    }
}
