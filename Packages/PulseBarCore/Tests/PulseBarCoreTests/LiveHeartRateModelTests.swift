import Foundation
import Testing
@testable import PulseBarCore

@MainActor
final class MockHeartRateSource: HeartRateSource {
    var onEvent: ((HeartRateSourceEvent) -> Void)?
    var calls: [String] = []
    func start() { calls.append("start") }
    func startScan() { calls.append("scan") }
    func stopScan() { calls.append("stopScan") }
    func connect(deviceID: UUID) { calls.append("connect \(deviceID)") }
    func disconnect() { calls.append("disconnect") }
    func send(_ e: HeartRateSourceEvent) { onEvent?(e) }
}

@MainActor
@Suite("LiveHeartRateModel")
struct LiveHeartRateModelTests {
    let source = MockHeartRateSource()
    let defaults: UserDefaults
    let device = DiscoveredDevice(id: UUID(), name: "Fitbit Air")
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    init() {
        let suite = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    func makeModel() -> LiveHeartRateModel {
        LiveHeartRateModel(source: source, defaults: defaults)
    }

    @Test("shows BPM only while connected with a fresh, valid reading")
    func displayBPM() {
        let model = makeModel()
        #expect(model.displayBPM == nil)
        source.send(.connection(.connected(name: "Fitbit Air")))
        source.send(.measurement(HeartRateMeasurement(bpm: 72), at: t0))
        #expect(model.displayBPM == 72)

        source.send(.measurement(HeartRateMeasurement(bpm: 0, sensorContact: .notDetected), at: t0))
        #expect(model.displayBPM == nil, "no skin contact → —")

        source.send(.measurement(HeartRateMeasurement(bpm: 75), at: t0))
        source.send(.connection(.reconnecting(name: "Fitbit Air")))
        #expect(model.displayBPM == nil, "link dropped → —")
    }

    @Test("sparkline keeps only the last 10 minutes and skips no-contact readings")
    func window() {
        let model = makeModel()
        source.send(.connection(.connected(name: "x")))
        for minute in 0...12 {
            source.send(.measurement(HeartRateMeasurement(bpm: 60 + minute), at: t0.addingTimeInterval(Double(minute) * 60)))
        }
        source.send(.measurement(HeartRateMeasurement(bpm: 0, sensorContact: .notDetected),
                                 at: t0.addingTimeInterval(12 * 60)))
        #expect(model.samples.first?.bpm == 62) // minute 2 = exactly 10 min before minute 12
        #expect(model.samples.last?.bpm == 72)
        #expect(model.samples.count == 11)
    }

    @Test("connecting remembers the device; powered-on auto-reconnects to it")
    func remembersDevice() {
        let model = makeModel()
        model.connect(to: device)
        #expect(source.calls.contains("connect \(device.id)"))

        let source2 = MockHeartRateSource()
        let relaunched = LiveHeartRateModel(source: source2, defaults: defaults)
        #expect(relaunched.rememberedDeviceID == device.id)
        source2.send(.availability(.poweredOn))
        #expect(source2.calls == ["connect \(device.id)"])
    }

    @Test("no remembered device → no connect on power-on")
    func noAutoConnect() {
        _ = makeModel()
        source.send(.availability(.poweredOn))
        #expect(source.calls.isEmpty)
    }

    @Test("forget disconnects and clears the remembered device")
    func forget() {
        let model = makeModel()
        model.connect(to: device)
        model.forgetDevice()
        #expect(model.rememberedDeviceID == nil)
        #expect(defaults.string(forKey: LiveHeartRateModel.rememberedDeviceKey) == nil)
        #expect(source.calls.last == "disconnect")
    }

    @Test("discovered devices are de-duplicated by id")
    func discovery() {
        let model = makeModel()
        model.startScan()
        source.send(.discovered(device))
        source.send(.discovered(DiscoveredDevice(id: device.id, name: "Renamed")))
        #expect(model.discovered.map(\.name) == ["Renamed"])
        #expect(model.isScanning)
    }

    @Test("detects whether the device sends RR intervals; resets on new connection")
    func rrDetection() {
        let model = makeModel()
        source.send(.connection(.connecting(name: "x")))
        source.send(.connection(.connected(name: "x")))
        source.send(.measurement(HeartRateMeasurement(bpm: 70), at: t0))
        #expect(!model.deviceSendsRR)
        #expect(model.readingsThisConnection == 1)
        source.send(.measurement(HeartRateMeasurement(bpm: 70, rrIntervalsMs: [850]), at: t0))
        #expect(model.deviceSendsRR)

        source.send(.connection(.connecting(name: "y")))
        #expect(!model.deviceSendsRR)
        #expect(model.readingsThisConnection == 0)
    }

    @Test("Bluetooth turning off stops scanning and blanks BPM")
    func poweredOff() {
        let model = makeModel()
        model.startScan()
        source.send(.connection(.connected(name: "x")))
        source.send(.measurement(HeartRateMeasurement(bpm: 70), at: t0))
        source.send(.availability(.poweredOff))
        #expect(!model.isScanning)
        #expect(model.displayBPM == nil)
    }
}
