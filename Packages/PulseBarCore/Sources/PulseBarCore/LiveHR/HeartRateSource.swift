import Foundation

/// Whether Bluetooth can be used right now (mirrors CBManagerState + authorization).
public enum BluetoothAvailability: Sendable, Equatable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

public struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public enum ConnectionState: Sendable, Equatable {
    case idle
    case connecting(name: String)
    case connected(name: String)
    /// Link dropped; waiting for the device to come back in range.
    case reconnecting(name: String)
}

public enum HeartRateSourceEvent: Sendable, Equatable {
    case availability(BluetoothAvailability)
    case discovered(DiscoveredDevice)
    case connection(ConnectionState)
    case measurement(HeartRateMeasurement, at: Date)
}

/// Anything that delivers live heart rate. The real implementation uses
/// CoreBluetooth; tests use a mock, so the model is testable without hardware.
@MainActor
public protocol HeartRateSource: AnyObject {
    var onEvent: ((HeartRateSourceEvent) -> Void)? { get set }
    func start()
    func startScan()
    func stopScan()
    func connect(deviceID: UUID)
    func disconnect()
}
