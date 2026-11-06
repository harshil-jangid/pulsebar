import Testing
@testable import PulseBarCore

@Suite("HeartRateZones")
struct HeartRateZonesTests {
    @Test("220 − age estimate")
    func ageEstimate() {
        #expect(HeartRateZones(age: 30)?.maxHR == 190)
        #expect(HeartRateZones(age: 5) == nil)
        #expect(HeartRateZones(maxHR: 60) == nil)
    }

    @Test("zone boundaries for max HR 190", arguments: [
        (94, HeartRateZone.belowZones),
        (95, .zone1),   // 50%
        (113, .zone1),
        (114, .zone2),  // 60%
        (132, .zone2),
        (133, .zone3),  // 70%
        (152, .zone4),  // 80%
        (171, .zone5),  // 90%
        (205, .zone5),  // above max still zone 5
    ])
    func boundaries(bpm: Int, zone: HeartRateZone) throws {
        let zones = try #require(HeartRateZones(maxHR: 190))
        #expect(zones.zone(for: bpm) == zone)
    }

    @Test("ranges agree with zone(for:) for every bpm, including non-round max HRs",
          arguments: [185, 190, 197])
    func rangesConsistent(maxHR: Int) throws {
        let zones = try #require(HeartRateZones(maxHR: maxHR))
        for zone in HeartRateZone.allCases {
            for bpm in zones.range(of: zone) {
                #expect(zones.zone(for: bpm) == zone, "bpm \(bpm) max \(maxHR)")
            }
        }
        #expect(zones.range(of: .zone2) == zones.range(of: .zone2)) // stable
    }

    @Test("Zone 2 band for max HR 190 is 114–132")
    func zone2Band() throws {
        #expect(try #require(HeartRateZones(maxHR: 190)).range(of: .zone2) == 114...132)
    }
}

@Suite("ReconnectBackoff")
struct ReconnectBackoffTests {
    @Test("doubles from base, caps, and resets")
    func sequence() {
        var b = ReconnectBackoff(base: 1, cap: 60)
        let delays = (0..<9).map { _ in b.nextDelay(jitter: 1) }
        #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60, 60])
        b.reset()
        #expect(b.nextDelay(jitter: 1) == 1)
    }

    @Test("jitter scales the delay")
    func jitter() {
        var b = ReconnectBackoff(base: 10, cap: 60)
        #expect(b.nextDelay(jitter: 0.8) == 8)
    }

    @Test("huge attempt counts don't overflow")
    func noOverflow() {
        var b = ReconnectBackoff()
        for _ in 0..<1000 { _ = b.nextDelay(jitter: 1) }
        #expect(b.nextDelay(jitter: 1) == 60)
    }
}
