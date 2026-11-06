/// Exponential backoff with jitter for failed Bluetooth connection attempts.
///
/// Only used when `connect` actively *fails*. A device that is merely out of
/// range is handled by a pending connect, which CoreBluetooth never times out,
/// so there is no retry loop and no CPU spin while waiting.
public struct ReconnectBackoff: Sendable {
    public let base: Double
    public let cap: Double
    public private(set) var attempt = 0

    public init(base: Double = 1, cap: Double = 60) {
        self.base = base
        self.cap = cap
    }

    /// Seconds to wait before the next attempt: base × 2^attempt, capped,
    /// then multiplied by `jitter` (default ±20%) so retries don't line up.
    public mutating func nextDelay(jitter: Double = Double.random(in: 0.8...1.2)) -> Double {
        let raw = min(cap, base * Double(1 << min(attempt, 16)))
        attempt += 1
        return raw * jitter
    }

    public mutating func reset() { attempt = 0 }
}
