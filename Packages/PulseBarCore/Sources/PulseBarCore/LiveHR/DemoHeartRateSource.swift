import Foundation

/// Simulated heart-rate device for demos, screenshots and UI work without a
/// wearable. Enabled by launching the app with `-demo`.
///
/// Plays a slow loop: resting (~68) → brisk walk (~115) → recovery, with
/// RR intervals, one reading per second.
@MainActor
public final class DemoHeartRateSource: HeartRateSource {
    public static let deviceID = UUID(uuidString: "00000000-0000-0000-0000-00000000DE70")!
    public var onEvent: ((HeartRateSourceEvent) -> Void)?
    private var task: Task<Void, Never>?
    private var tick = 0

    public init() {}

    public func start() { onEvent?(.availability(.poweredOn)) }
    public func startScan() { onEvent?(.discovered(DiscoveredDevice(id: Self.deviceID, name: "Demo strap"))) }
    public func stopScan() {}

    public func connect(deviceID: UUID) {
        onEvent?(.connection(.connecting(name: "Demo strap")))
        onEvent?(.connection(.connected(name: "Demo strap")))
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.emit()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func disconnect() {
        task?.cancel()
        onEvent?(.connection(.idle))
    }

    /// Deterministic BPM for a given second, exposed for tests.
    nonisolated public static func bpm(at tick: Int) -> Int {
        let phase = Double(tick % 600) / 600 * 2 * .pi          // 10-minute cycle
        let effort = max(0, sin(phase))                           // half the cycle active
        let wobble = sin(Double(tick) / 7) * 2
        return Int((68 + effort * 47 + wobble).rounded())
    }

    private func emit() {
        let bpm = Self.bpm(at: tick)
        tick += 1
        let rr = 60_000.0 / Double(bpm)
        onEvent?(.measurement(HeartRateMeasurement(bpm: bpm, sensorContact: .detected,
                                                   rrIntervalsMs: [rr]), at: Date()))
    }
}
