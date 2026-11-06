import Foundation

/// One decoded Bluetooth Heart Rate Measurement (characteristic 0x2A37).
///
/// Layout per the Bluetooth SIG GATT Specification Supplement
/// (org.bluetooth.characteristic.heart_rate_measurement), all little-endian:
///
/// | Field          | Size        | Present when      |
/// |----------------|-------------|-------------------|
/// | Flags          | 1           | always            |
/// | HR value       | 1 or 2      | bit 0: 0 = uint8, 1 = uint16 |
/// | Energy expended| 2           | bit 3 set         |
/// | RR-intervals   | 2 × n       | bit 4 set (n from remaining length) |
///
/// Flags bit 1 = sensor contact detected, bit 2 = sensor contact supported,
/// bits 5–7 reserved (ignored).
public struct HeartRateMeasurement: Sendable, Equatable {
    public enum SensorContact: Sendable, Equatable {
        case notSupported
        case notDetected
        case detected
    }

    public var bpm: Int
    public var sensorContact: SensorContact
    /// Raw cumulative energy value. The Heart Rate Service spec defines the unit
    /// as kilojoules; we keep the raw number and don't use it for any metric.
    public var energyExpended: Int?
    /// Beat-to-beat intervals in milliseconds, oldest first. Empty if the
    /// device doesn't send them.
    public var rrIntervalsMs: [Double]

    public init(bpm: Int, sensorContact: SensorContact = .notSupported,
                energyExpended: Int? = nil, rrIntervalsMs: [Double] = []) {
        self.bpm = bpm
        self.sensorContact = sensorContact
        self.energyExpended = energyExpended
        self.rrIntervalsMs = rrIntervalsMs
    }

    /// False only when the device says it supports contact detection and
    /// reports no skin contact; then the BPM value is not meaningful.
    public var hasValidContact: Bool { sensorContact != .notDetected }
}

public enum HeartRateParseError: Error, Equatable {
    case empty
    case truncated
}

extension HeartRateMeasurement {
    /// Decodes a raw 0x2A37 notification payload.
    ///
    /// Throws if the payload is too short for the fields its flags announce.
    /// A single dangling byte after the RR-intervals is ignored rather than
    /// rejecting the whole reading.
    public static func parse(_ data: Data) throws -> HeartRateMeasurement {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { throw HeartRateParseError.empty }
        var index = 1

        func readUInt8() throws -> Int {
            guard index < bytes.count else { throw HeartRateParseError.truncated }
            defer { index += 1 }
            return Int(bytes[index])
        }
        func readUInt16() throws -> Int {
            guard index + 1 < bytes.count else { throw HeartRateParseError.truncated }
            defer { index += 2 }
            return Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
        }

        let is16Bit = flags & 0b0000_0001 != 0
        let contactDetected = flags & 0b0000_0010 != 0
        let contactSupported = flags & 0b0000_0100 != 0
        let hasEnergy = flags & 0b0000_1000 != 0
        let hasRR = flags & 0b0001_0000 != 0

        let bpm = is16Bit ? try readUInt16() : try readUInt8()
        let energy = hasEnergy ? try readUInt16() : nil

        var rr: [Double] = []
        if hasRR {
            while index + 1 < bytes.count {
                rr.append(Double(try readUInt16()) * 1000.0 / 1024.0)
            }
        }

        let contact: SensorContact = !contactSupported ? .notSupported
            : (contactDetected ? .detected : .notDetected)
        return HeartRateMeasurement(bpm: bpm, sensorContact: contact,
                                    energyExpended: energy, rrIntervalsMs: rr)
    }
}
