import CoreBluetooth
import Foundation
import os

/// Live heart rate from any device exposing the standard Bluetooth
/// Heart Rate Service (0x180D).
///
/// Read-only by design (spec F2.8): the only thing we ever write is the
/// standard notify subscription on 0x2A37. No commands, no pairing changes.
///
/// Reconnect strategy (no polling):
/// - Link drops → the system auto-reconnects (`CBConnectPeripheralOptionEnableAutoReconnect`,
///   macOS 14+); if it doesn't, we issue a pending `connect`, which never times out
///   and completes when the device is back in range.
/// - `connect` actively fails → retry with exponential backoff.
@MainActor
public final class CoreBluetoothHeartRateSource: NSObject, HeartRateSource {
    public static let heartRateService = CBUUID(string: "180D")
    public static let heartRateMeasurement = CBUUID(string: "2A37")

    public var onEvent: ((HeartRateSourceEvent) -> Void)?

    private var central: CBCentralManager?
    private var known: [UUID: CBPeripheral] = [:]
    private var target: CBPeripheral?
    private var targetID: UUID?
    private var wantsScan = false
    private var backoff = ReconnectBackoff()
    private var retryTask: Task<Void, Never>?
    private let log = Logger(subsystem: "io.github.pulsebar", category: "LiveHR")

    override public init() { super.init() }

    /// Creates the central manager. This is what triggers the macOS
    /// Bluetooth permission prompt on first run.
    public func start() {
        guard central == nil else { return }
        central = CBCentralManager(
            delegate: self, queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false] // we show our own message
        )
    }

    public func startScan() {
        wantsScan = true
        guard let central, central.state == .poweredOn else { return }
        // Devices already connected to this Mac (e.g. by another app) don't advertise.
        for p in central.retrieveConnectedPeripherals(withServices: [Self.heartRateService]) {
            remember(p, advertisedName: nil)
        }
        central.scanForPeripherals(withServices: [Self.heartRateService])
    }

    public func stopScan() {
        wantsScan = false
        central?.stopScan()
    }

    public func connect(deviceID: UUID) {
        retryTask?.cancel()
        if let old = target, old.identifier != deviceID { central?.cancelPeripheralConnection(old) }
        targetID = deviceID
        backoff.reset()
        attemptConnect()
    }

    public func disconnect() {
        retryTask?.cancel()
        targetID = nil
        if let target { central?.cancelPeripheralConnection(target) }
        target = nil
        onEvent?(.connection(.idle))
    }

    // MARK: - Private

    private func attemptConnect() {
        guard let central, central.state == .poweredOn, let targetID else { return }
        guard let p = known[targetID]
                ?? central.retrievePeripherals(withIdentifiers: [targetID]).first else {
            // Not known to the system (e.g. Bluetooth cache reset): rescan to find it.
            log.notice("Remembered device not found; scanning")
            startScan()
            return
        }
        target = p
        p.delegate = self
        onEvent?(.connection(.connecting(name: displayName(p))))
        central.connect(p, options: [CBConnectPeripheralOptionEnableAutoReconnect: true])
    }

    private func scheduleRetry() {
        let delay = backoff.nextDelay()
        log.notice("Connect failed; retrying in \(delay, format: .fixed(precision: 1))s")
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.attemptConnect()
        }
    }

    private func remember(_ p: CBPeripheral, advertisedName: String?) {
        known[p.identifier] = p
        let name = advertisedName ?? p.name ?? "Heart-rate device"
        onEvent?(.discovered(DiscoveredDevice(id: p.identifier, name: name)))
        // Found the remembered device after a cache reset → connect now.
        if p.identifier == targetID, target == nil {
            stopScan()
            attemptConnect()
        }
    }

    private func displayName(_ p: CBPeripheral) -> String { p.name ?? "Heart-rate device" }

    private static func availability(_ c: CBCentralManager) -> BluetoothAvailability {
        if CBManager.authorization == .denied || CBManager.authorization == .restricted {
            return .unauthorized
        }
        switch c.state {
        case .poweredOn: return .poweredOn
        case .poweredOff: return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        case .resetting: return .resetting
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }
}

// Callbacks arrive on the main queue (see `start()`), matching @MainActor.
extension CoreBluetoothHeartRateSource: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = Self.availability(central)
        onEvent?(.availability(state))
        if state == .poweredOn {
            if wantsScan { startScan() }
            // The model may already have called connect() in response to .availability.
            if targetID != nil, target == nil { attemptConnect() }
        } else {
            // Peripherals are invalid until Bluetooth is back; keep targetID to resume.
            retryTask?.cancel()
            target = nil
            known.removeAll()
            onEvent?(.connection(.idle))
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        remember(peripheral, advertisedName: advertisementData[CBAdvertisementDataLocalNameKey] as? String)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == targetID else { return }
        backoff.reset()
        onEvent?(.connection(.connected(name: displayName(peripheral))))
        peripheral.discoverServices([Self.heartRateService])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        guard peripheral.identifier == targetID else { return }
        onEvent?(.connection(.reconnecting(name: displayName(peripheral))))
        scheduleRetry()
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        guard peripheral.identifier == targetID else { return }
        onEvent?(.connection(.reconnecting(name: displayName(peripheral))))
        if !isReconnecting {
            // Pending connect: no timeout, completes when the device returns.
            central.connect(peripheral, options: [CBConnectPeripheralOptionEnableAutoReconnect: true])
        }
    }
}

extension CoreBluetoothHeartRateSource: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.heartRateService }) else {
            log.error("Heart Rate Service not found on device")
            return
        }
        peripheral.discoverCharacteristics([Self.heartRateMeasurement], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        guard let c = service.characteristics?.first(where: { $0.uuid == Self.heartRateMeasurement }) else {
            log.error("Heart Rate Measurement characteristic not found")
            return
        }
        peripheral.setNotifyValue(true, for: c) // the only "write": standard notify subscription
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == Self.heartRateMeasurement, let data = characteristic.value else { return }
        do {
            onEvent?(.measurement(try HeartRateMeasurement.parse(data), at: Date()))
        } catch {
            // Never log raw health values (spec §4 privacy); the error kind is enough.
            log.error("Ignoring malformed heart-rate packet: \(String(describing: error), privacy: .public)")
        }
    }
}
