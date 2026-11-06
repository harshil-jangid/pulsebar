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
        live.start()
        Task { await prepareNotifications() }
        scheduleSync()
    }

    func syncInBackground() {
        Task { await google.sync() }
    }

    /// Sync on launch, on wake, and every 3 hours (F3.5). The timer has a large
    /// tolerance so macOS can coalesce it with other work (battery, spec §4).
    @ObservationIgnored private var syncTimer: Timer?
    private func scheduleSync() {
        guard !isDemo else { return }
        Task { await google.sync() }
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

    /// Resting HR used for the nudge threshold: personal baseline once available
    /// (M4), otherwise the user's fallback setting.
    var restingHRForNudge: Int { settings.value.fallbackRestingHR }

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

    private func prepareNotifications() async {
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
