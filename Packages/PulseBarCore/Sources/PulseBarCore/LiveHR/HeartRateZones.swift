/// Heart-rate training zones as a percentage of max HR (common 5-zone model).
///
/// | Zone | % of max | Label |
/// |------|----------|-------|
/// | 1    | 50–59    | Very light |
/// | 2    | 60–69    | Easy (the "Zone 2" aerobic base band) |
/// | 3    | 70–79    | Moderate |
/// | 4    | 80–89    | Hard |
/// | 5    | 90+      | Maximum |
public enum HeartRateZone: Int, CaseIterable, Sendable, Comparable {
    case belowZones = 0, zone1, zone2, zone3, zone4, zone5

    /// Lower bound as a percentage of max HR.
    var lowerPercent: Int { rawValue == 0 ? 0 : 40 + rawValue * 10 }

    public var title: String {
        switch self {
        case .belowZones: "Resting"
        case .zone1: "Zone 1 · Very light"
        case .zone2: "Zone 2 · Easy"
        case .zone3: "Zone 3 · Moderate"
        case .zone4: "Zone 4 · Hard"
        case .zone5: "Zone 5 · Maximum"
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct HeartRateZones: Sendable, Equatable {
    public static let plausibleMaxHR = 120...230

    public let maxHR: Int

    /// Returns nil for implausible values so the UI shows "set your age" instead.
    public init?(maxHR: Int) {
        guard Self.plausibleMaxHR.contains(maxHR) else { return nil }
        self.maxHR = maxHR
    }

    /// Default estimate from the spec (F2.7): 220 − age.
    public init?(age: Int) {
        guard (10...100).contains(age) else { return nil }
        self.init(maxHR: 220 - age)
    }

    public func zone(for bpm: Int) -> HeartRateZone {
        // Integer math avoids rounding surprises at the boundaries.
        HeartRateZone.allCases.last { bpm * 100 >= maxHR * $0.lowerPercent } ?? .belowZones
    }

    /// Inclusive BPM range for a zone (zone 5 ends at max HR).
    public func range(of zone: HeartRateZone) -> ClosedRange<Int> {
        let lower = Int((Double(maxHR * zone.lowerPercent) / 100).rounded(.up))
        guard let next = HeartRateZone(rawValue: zone.rawValue + 1) else {
            return lower...max(lower, maxHR)
        }
        let nextLower = Int((Double(maxHR * next.lowerPercent) / 100).rounded(.up))
        return lower...(nextLower - 1)
    }
}
