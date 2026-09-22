import XCTest
@testable import Skynet

/// Shared helpers for the test suite. Tests run against the scripted
/// fixtures in `Skynet/PreviewSupport` (see the README wiring notes).
enum TestSupport {
    /// Yields briefly so event-stream tasks enqueued on the main actor get a
    /// chance to run. Most tests should prefer `waitUntil`.
    @MainActor
    static func drainMainActor(rounds: Int = 20, delayNanos: UInt64 = 5_000_000) async {
        for _ in 0..<rounds {
            try? await Task.sleep(nanoseconds: delayNanos)
        }
    }

    /// Polls `condition` on the main actor until it holds or the timeout
    /// elapses. Returns the final value of the condition.
    @discardableResult
    @MainActor
    static func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// Standard fixtures for view-model tests: a relay wired with the
    /// standard preview data plus an in-memory machine store.
    static func standardRelay() -> ScriptedRelay {
        PreviewData.scriptedRelay()
    }
}
