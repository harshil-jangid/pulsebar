import AppKit
import Observation
import os
import PulseBarCore

/// Owns every long-lived service and wires them together.
/// Created once at launch by `PulseBarApp`.
@MainActor
@Observable
final class AppEnvironment {
    let isDemo: Bool
    let db: AppDatabase
    let settings: SettingsStore
    let live: LiveHeartRateModel
    let recorder: SessionRecorder
    let notifier: Notifier
    let google: GoogleSync
    /// Shown in the popover if the database couldn't be opened (data then isn't saved).
    private(set) var storageError: String?

    // Derived daily data (M4), refreshed after each sync and at day change.
    private(set) var dailyRows: [DailyMetric] = []
    private(set) var readiness: Readiness?
    private(set) var goal: Goal?
    private(set) var restingBaseline: Baseline?

    @ObservationIgnored private var nudge: NudgeEngine
    @ObservationIgnored private let log = Logger(subsystem: "io.github.pulsebar", category: "App")

    init(demo: Bool) {
        isDemo = demo
        let (db, storageError) = Self.openDatabase(demo: demo)
        self.db = db
        self.storageError = storageError

        let settings = SettingsStore(db: db)
        Self.migrateLegacyDefaults(into: settings, demo: demo)
        self.settings = settings

        let source: HeartRateSource = demo ? DemoHeartRateSource() : CoreBluetoothHeartRateSource()
        if demo { settings.rememberedDeviceID = DemoHeartRateSource.deviceID }
        live = LiveHeartRateModel(source: source, memory: settings)
        recorder = SessionRecorder(db: db)
        notifier = SystemNotifier()
        google = GoogleSync(db: db, settings: settings,
                            secrets: demo ? MemorySecretStore() : KeychainStore())
        nudge = NudgeEngine(lastNudgeAt: settings.value.lastNudgeAt)

        live.eventObserver = { [weak self] event in self?.handle(event) }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recorder.endSession(at: Date()) }
        }
    }

    func start() {
        if isDemo { DemoData.seed(db) }
        live.start()
        refreshMetrics()
        if settings.value.onboardingCompleted { Task { await prepareNotifications() } }
        scheduleSync()
        scheduleMorningCheck()
    }

    func syncInBackground() {
        Task {
            await google.sync()
            refreshMetrics()
        }
    }

    /// Recomputes readiness, baselines and goal from the database, then sends
    /// the morning card if it's due.
    func refreshMetrics(now: Date = Date()) {
        let today = LocalDay.string(now)
        dailyRows = (try? db.allDailyMetrics()) ?? []
        readiness = Readiness.compute(date: today, rows: dailyRows)
        restingBaseline = Baseline.compute(.restingHR, before: today, in: dailyRows)
        goal = try? db.ensureStartSnapshot()
        sendMorningCardIfDue(now: now)
    }

    func saveGoal(_ goal: Goal) {
        try? db.saveGoal(goal)
        refreshMetrics()
    }

    private func sendMorningCardIfDue(now: Date) {
        guard let readiness, let card = MorningCard.message(now: now, settings: settings.value, readiness: readiness) else { return }
        settings.update { $0.lastMorningNotificationDay = LocalDay.string(now) }
        Task { await notifier.post(id: "morning-\(readiness.date)", title: card.title, body: card.body) }
    }

    /// One timer per day at the chosen morning time (no polling).
    @ObservationIgnored private var morningTimer: Timer?
    func scheduleMorningCheck(now: Date = Date()) {
        morningTimer?.invalidate()
        let minute = settings.value.morningReadinessMinute
        var next = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: now)!
        if next <= now { next = Calendar.current.date(byAdding: .day, value: 1, to: next)! }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncInBackground()     // refreshMetrics → morning card once data is in
                self?.scheduleMorningCheck()
            }
        }
        timer.tolerance = 120
        RunLoop.main.add(timer, forMode: .common)
        morningTimer = timer
    }

    /// Sync on launch, on wake, and every 3 hours (F3.5). The timer has a large
    /// tolerance so macOS can coalesce it with other work (battery, spec §4).
    @ObservationIgnored private var syncTimer: Timer?
    private func scheduleSync() {
        guard !isDemo else { return }
        syncInBackground()
        let timer = Timer(timeInterval: 3 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncInBackground() }
        }
        timer.tolerance = 15 * 60
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncInBackground() }
        }
    }

    /// Resting HR used for the nudge threshold: personal 30-day baseline once
    /// calibrated, otherwise the user's fallback setting (F2.6).
    var restingHRForNudge: Int {
        if let b = restingBaseline, b.isCalibrated { return Int(b.median.rounded()) }
        return settings.value.fallbackRestingHR
    }

    private func handle(_ event: HeartRateSourceEvent) {
        recorder.handle(event)
        guard case .measurement(let m, let date) = event, m.hasValidContact else { return }
        let fire = nudge.ingest(bpm: m.bpm, at: date, restingHR: restingHRForNudge,
                                inWorkout: recorder.isWorkout, settings: settings.value)
        if fire {
            settings.update { $0.lastNudgeAt = date }
            let minutes = settings.value.nudgeSustainedMinutes
            Task { await notifier.post(id: "nudge-\(date.timeIntervalSince1970)",
                                       title: NudgeEngine.title, body: NudgeEngine.body(minutes: minutes)) }
        }
    }

    func prepareNotifications() async {
        if settings.value.nudgeEnabled || settings.value.checkinReminderEnabled {
            _ = await notifier.requestAuthorization()
        }
    }

    private static func openDatabase(demo: Bool) -> (AppDatabase, String?) {
        // Demo data never touches your real database.
        if demo { return (try! AppDatabase.inMemory(), nil) }
        do {
            let db = try AppDatabase.openShared()
            try db.recoverOpenSessions()
            return (db, nil)
        } catch {
            return (try! AppDatabase.inMemory(),
                    "Couldn't open the PulseBar database. Live heart rate works, but nothing is saved.")
        }
    }

    /// M1 kept age / max HR / device in UserDefaults; move them into the database once.
    private static func migrateLegacyDefaults(into settings: SettingsStore, demo: Bool) {
        guard !demo else { return }
        let d = UserDefaults.standard
        settings.update { s in
            if s.age == nil, d.integer(forKey: "zones.age") > 0 { s.age = d.integer(forKey: "zones.age") }
            if s.maxHROverride == nil, d.integer(forKey: "zones.maxHROverride") > 0 {
                s.maxHROverride = d.integer(forKey: "zones.maxHROverride")
            }
            if s.rememberedDeviceID == nil {
                s.rememberedDeviceID = d.string(forKey: "liveHR.rememberedDeviceID").flatMap(UUID.init)
            }
        }
        for key in ["zones.age", "zones.maxHROverride", "liveHR.rememberedDeviceID"] { d.removeObject(forKey: key) }
    }
}
