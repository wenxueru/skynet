import Foundation

/// Exponential backoff with jitter for relay reconnection attempts.
/// Pure and clock-free so the schedule is directly unit-testable.
public struct ReconnectPolicy: Sendable {
    /// Delay before the first retry.
    public var baseDelay: Duration
    /// Ceiling for the computed delay.
    public var maxDelay: Duration
    /// Multiplier applied after each failed attempt.
    public var multiplier: Double

    public init(
        baseDelay: Duration = .milliseconds(500),
        maxDelay: Duration = .seconds(30),
        multiplier: Double = 2.0
    ) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
    }

    /// Delay to wait before attempt `attempt` (1-based, i.e. the delay after
    /// the first failure is `delay(afterAttempt: 1)`).
    public func delay(afterAttempt attempt: Int, jitter: Double = 0) -> Duration {
        let capped = min(attempt, 62) // avoid overflowing Double with 2^n
        let seconds = baseDelay.components.seconds
        let attoseconds = baseDelay.components.attoseconds
        let base = Double(seconds) + Double(attoseconds) / 1e18
        var scaled = base * pow(multiplier, Double(max(0, capped - 1)))
        if jitter > 0 {
            let jitterRange = scaled * jitter
            scaled += (Double.random(in: -jitterRange...jitterRange))
        }
        scaled = min(max(0, scaled), maxDelaySeconds)
        return .seconds(scaled)
    }

    private var maxDelaySeconds: Double {
        let seconds = maxDelay.components.seconds
        let attoseconds = maxDelay.components.attoseconds
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

/// Something that can sleep — production uses a real clock, tests use an
/// immediate no-op. Keeps reconnect logic testable without waiting.
public protocol DurationSleeper: Sendable {
    func sleep(for duration: Duration) async
}

/// Real-world sleeper.
public struct ClockSleeper: DurationSleeper {
    private let clock = ContinuousClock()

    public init() {}

    public func sleep(for duration: Duration) async {
        try? await clock.sleep(for: duration)
    }
}

/// Test sleeper: records the requested durations and returns immediately.
public final class RecordedSleeper: DurationSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDurations: [Duration] = []

    public init() {}

    public func sleep(for duration: Duration) async {
        lock.withLock {
            recordedDurations.append(duration)
        }
    }

    public var recorded: [Duration] {
        lock.withLock { recordedDurations }
    }
}
