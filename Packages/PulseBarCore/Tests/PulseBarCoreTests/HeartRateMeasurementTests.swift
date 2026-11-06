import Foundation
import Testing
@testable import PulseBarCore

@Suite("HeartRateMeasurement.parse (0x2A37)")
struct HeartRateMeasurementTests {
    private func parse(_ bytes: [UInt8]) throws -> HeartRateMeasurement {
        try HeartRateMeasurement.parse(Data(bytes))
    }

    @Test("8-bit BPM, no optional fields")
    func uint8() throws {
        let m = try parse([0x00, 72])
        #expect(m == HeartRateMeasurement(bpm: 72))
    }

    @Test("16-bit BPM is little-endian")
    func uint16() throws {
        // 0x012C = 300 (above uint8 range)
        #expect(try parse([0x01, 0x2C, 0x01]).bpm == 300)
        #expect(try parse([0x01, 72, 0x00]).bpm == 72)
    }

    @Test("sensor contact: all four bit combinations", arguments: [
        (UInt8(0b000), HeartRateMeasurement.SensorContact.notSupported),
        (UInt8(0b010), .notSupported), // detected bit without supported bit
        (UInt8(0b100), .notDetected),
        (UInt8(0b110), .detected),
    ])
    func contact(flags: UInt8, expected: HeartRateMeasurement.SensorContact) throws {
        let m = try parse([flags, 60])
        #expect(m.sensorContact == expected)
        #expect(m.hasValidContact == (expected != .notDetected))
    }

    @Test("energy expended present")
    func energy() throws {
        let m = try parse([0x08, 80, 0x10, 0x27]) // 0x2710 = 10000
        #expect(m.energyExpended == 10_000)
        #expect(m.rrIntervalsMs.isEmpty)
    }

    @Test("RR intervals convert from 1/1024 s to ms, oldest first")
    func rrIntervals() throws {
        // 1024 → 1000 ms, 768 → 750 ms
        let m = try parse([0x10, 60, 0x00, 0x04, 0x00, 0x03])
        #expect(m.rrIntervalsMs == [1000, 750])
    }

    @Test("everything at once: 16-bit + contact + energy + RR")
    func allFields() throws {
        let m = try parse([0b0001_1111, 0x5A, 0x00, 0x64, 0x00, 0x00, 0x02])
        #expect(m == HeartRateMeasurement(
            bpm: 90, sensorContact: .detected, energyExpended: 100, rrIntervalsMs: [500]))
    }

    @Test("RR flag set but no RR values is allowed")
    func rrFlagNoValues() throws {
        #expect(try parse([0x10, 60]).rrIntervalsMs.isEmpty)
    }

    @Test("dangling odd byte after RR values is ignored")
    func danglingByte() throws {
        #expect(try parse([0x10, 60, 0x00, 0x04, 0xFF]).rrIntervalsMs == [1000])
    }

    @Test("reserved bits 5–7 are ignored")
    func reservedBits() throws {
        #expect(try parse([0b1110_0000, 65]) == HeartRateMeasurement(bpm: 65))
    }

    @Test("malformed payloads throw", arguments: [
        ([UInt8](), HeartRateParseError.empty),
        ([0x00], .truncated),             // no 8-bit value
        ([0x01, 0x48], .truncated),       // 16-bit value cut short
        ([0x08, 60, 0x10], .truncated),   // energy cut short
    ])
    func malformed(bytes: [UInt8], error: HeartRateParseError) {
        #expect(throws: error) { try parse(bytes) }
    }
}
