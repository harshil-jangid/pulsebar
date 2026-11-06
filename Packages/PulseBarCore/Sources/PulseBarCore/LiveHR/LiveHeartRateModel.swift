import Foundation
import Observation

public struct HeartRateSample: Sendable, Equatable, Identifiable {
    public let date: Date
    public let bpm: Int
    public var id: Date { date }
}

/// UI-facing state for live heart rate. Drives the menu bar and the popover.
///
/// Event-driven: it changes only when the source reports something, plus one
/// cancellable "stale" timer per reading, so it costs nothing while idle.
@MainActor
@Observable
public final class LiveHeartRateModel {
    public static let rememberedDeviceKey = "liveHR.rememberedDeviceID"
    /// How long a reading counts as "live" without a newer one.
    public static let staleAfter: Duration = .seconds(10)

    public private(set) var availability: BluetoothAvailability = .unknown
    public private(set) var connection: ConnectionState = .idle
    public private(set) var discovered: [DiscoveredDevice] = []
    public private(set) var isScanning = false
    public private(set) var latest: HeartRateMeasurement?
    public private(set) var isFresh = false
    /// Samples from the last `window` seconds, oldest first, for the sparkline.
    public private(set) var samples: [HeartRateSample] = []
    public let window: TimeInterval

    public private(set) var rememberedDeviceID: UUID?

    private let source: HeartRateSource
    private let defaults: UserDefaults
    @ObservationIgnored private var staleTask: Task<Void, Never>?

    public init(source: HeartRateSource, defaults: UserDefaults = .standard, window: TimeInterval = 600) {
        self.source = source
        self.defaults = defaults
        self.window = window
        rememberedDeviceID = defaults.string(forKey: Self.rememberedDeviceKey).flatMap(UUID.init)
        source.onEvent = { [weak self] in self?.handle($0) }
    }

    /// BPM to show, or nil ("—") when disconnected, stale, or no skin contact.
    public var displayBPM: Int? {
        guard isFresh, case .connected = connection, let latest, latest.hasValidContact else { return nil }
        return latest.bpm
    }

    public func start() { source.start() }

    public func startScan() {
        discovered = []
        isScanning = true
        source.startScan()
    }

    public func stopScan() {
        isScanning = false
        source.stopScan()
    }

    /// Connects and remembers the device for auto-reconnect on next launch.
    public func connect(to device: DiscoveredDevice) {
        stopScan()
        rememberedDeviceID = device.id
        defaults.set(device.id.uuidString, forKey: Self.rememberedDeviceKey)
        source.connect(deviceID: device.id)
    }

    /// Disconnects and forgets the device.
    public func forgetDevice() {
        source.disconnect()
        rememberedDeviceID = nil
        defaults.removeObject(forKey: Self.rememberedDeviceKey)
        connection = .idle
        clearLive()
    }

    func handle(_ event: HeartRateSourceEvent) {
        switch event {
        case .availability(let value):
            availability = value
            if value == .poweredOn {
                if let id = rememberedDeviceID, connection == .idle { source.connect(deviceID: id) }
            } else {
                isScanning = false
                clearLive()
            }
        case .discovered(let device):
            if let i = discovered.firstIndex(where: { $0.id == device.id }) {
                discovered[i] = device
            } else {
                discovered.append(device)
            }
        case .connection(let state):
            connection = state
            if case .connected = state {} else { clearLive() }
        case .measurement(let m, let date):
            latest = m
            if m.hasValidContact {
                samples.append(HeartRateSample(date: date, bpm: m.bpm))
            }
            let cutoff = date.addingTimeInterval(-window)
            if let first = samples.firstIndex(where: { $0.date >= cutoff }), first > 0 {
                samples.removeFirst(first)
            }
            markFresh()
        }
    }

    private func markFresh() {
        isFresh = true
        staleTask?.cancel()
        staleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.staleAfter)
            guard !Task.isCancelled else { return }
            self?.isFresh = false
        }
    }

    private func clearLive() {
        staleTask?.cancel()
        isFresh = false
    }
}
