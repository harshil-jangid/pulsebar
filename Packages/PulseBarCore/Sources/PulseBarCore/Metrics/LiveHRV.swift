import Foundation

/// Short-window HRV from live RR intervals (spec F2.5).
///
/// This is *live HRV*: measured while awake and moving. It is NOT comparable to
/// the sleep-based HRV from Google Health and must never be mixed into those baselines.
public enum LiveHRV {
    /// Physiologically plausible RR range (30–200 bpm).
    public static let plausibleRR: ClosedRange<Double> = 300...2000
    /// Minimum clean intervals for a meaningful value.
    public static let minimumIntervals = 10

    /// Root mean square of successive differences, in ms.
    ///
    /// Artifact handling: drops intervals outside `plausibleRR`, and skips a
    /// successive difference when the interval changed by more than 20% from
    /// the previous one (typical of missed or extra beats).
    public static func rmssd(_ rrMs: [Double]) -> Double? {
        let clean = rrMs.filter(plausibleRR.contains)
        guard clean.count >= minimumIntervals else { return nil }
        var sumSquares = 0.0
        var count = 0
        for (a, b) in zip(clean, clean.dropFirst()) where abs(b - a) <= 0.2 * a {
            sumSquares += (b - a) * (b - a)
            count += 1
        }
        guard count >= minimumIntervals - 1 else { return nil }
        return (sumSquares / Double(count)).squareRoot()
    }
}
