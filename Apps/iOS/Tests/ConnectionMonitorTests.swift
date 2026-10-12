import SkynetMobile
import XCTest
@testable import Skynet

/// A relay whose reconnect can be scripted to keep failing — used to observe
/// the monitor's backoff loop without real sleeping.
private final class FlakyRelay: SkynetRelay, @unchecked Sendable {
    let machineID = MachineID("flaky")

    private let channel = EventChannel<ConnectionState>(replaysLastValue: true)
    private let lock = NSLock()
    private var reconnectCountStorage = 0

    /// Connection state pushed by `reconnect()`. Defaults to still-down so
    /// the monitor's loop keeps retrying.
    var reconnectOutcome: ConnectionState = .disconnected(reason: "still down")

    var reconnectCount: Int {
        lock.withLock { reconnectCountStorage }
    }

    func connectionEvents() -> AsyncStream<ConnectionState> {
        channel.stream()
    }

    func reconnect() async {
        let outcome = reconnectOutcome
        lock.withLock { reconnectCountStorage += 1 }
        channel.send(outcome)
    }

    func push(_ state: ConnectionState) {
        channel.send(state)
    }

    // Unused in these tests.
    func projects() async throws -> [Project] { [] }
    func sessions(in project: ProjectID) async throws -> [AgentSession] { [] }
    func createSession(in project: ProjectID, configuration: AgentConfiguration) async throws -> AgentSession {
        throw SkynetError.notPaired
    }
    func renameSession(_ sessionID: SessionID, to title: String) async throws {}
    func deleteSession(_ sessionID: SessionID) async throws {}
    func availableModels() async throws -> [AgentModel] { [] }
    func updateConfiguration(_ configuration: AgentConfiguration, for sessionID: SessionID) async throws {}
    func sessionEvents(for sessionID: SessionID) -> AsyncStream<SessionEvent> {
        AsyncStream { $0.finish() }
    }
    func sendPrompt(_ prompt: PromptPayload, to sessionID: SessionID) async throws {}
    func cancelCurrentTurn(in sessionID: SessionID) async throws {}
    func resolvePermission(
        _ requestID: TranscriptItemID,
        decision: PermissionDecision,
        in sessionID: SessionID
    ) async throws {}
}

/// Each retry delay advances only when the test releases it. Cancellation
/// resumes its waiter so a manual retry can drain a canceled backoff task.
private final class GatedSleeper: DurationSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Duration] = []
    private var waiters: [(UUID, CheckedContinuation<Void, Never>)] = []

    var recorded: [Duration] { lock.withLock { durations } }

    func sleep(for duration: Duration) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let installed = lock.withLock {
                    guard !Task.isCancelled else { return false }
                    durations.append(duration)
                    waiters.append((id, continuation))
                    return true
                }
                if !installed { continuation.resume() }
            }
        } onCancel: {
            let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard let index = self.waiters.firstIndex(where: { $0.0 == id }) else { return nil }
                return self.waiters.remove(at: index).1
            }
            continuation?.resume()
        }
    }

    func releaseNext() {
        let continuation = lock.withLock { waiters.isEmpty ? nil : waiters.removeFirst().1 }
        continuation?.resume()
    }
}

@MainActor
final class ConnectionMonitorTests: XCTestCase {
    private var relay: ScriptedRelay!
    private var flaky: FlakyRelay!
    private var sleeper: GatedSleeper!

    override func setUp() {
        super.setUp()
        relay = PreviewData.scriptedRelay()
        flaky = FlakyRelay()
        sleeper = GatedSleeper()
    }

    func testStartPicksUpReplayedConnectionState() async {
        let monitor = ConnectionMonitorModel(relay: relay, sleeper: sleeper)
        defer { monitor.stop() }
        XCTAssertEqual(monitor.state, .initial)
        monitor.start()
        let connected = await TestSupport.waitUntil { monitor.state.isConnected }
        XCTAssertTrue(connected, "the relay's replayed connected state should apply immediately")
    }

    func testDisconnectSchedulesBackoffReconnect() async {
        let monitor = ConnectionMonitorModel(relay: relay, sleeper: sleeper)
        defer { monitor.stop() }
        monitor.start()
        _ = await TestSupport.waitUntil { monitor.state.isConnected }

        relay.pushConnection(.disconnected(reason: "link dropped"))
        let scheduled = await TestSupport.waitUntil {
            monitor.reconnectAttempt >= 1 && !sleeper.recorded.isEmpty
        }
        XCTAssertTrue(scheduled, "a disconnect should schedule the first backoff attempt")
        XCTAssertFalse(monitor.state.isConnected)
        XCTAssertEqual(relay.reconnectCallCount, 0, "the retry must wait for backoff")

        // The scripted relay reconnects instantly; the monitor should settle
        // back to connected and stop the loop.
        sleeper.releaseNext()
        let restored = await TestSupport.waitUntil {
            monitor.state.isConnected && monitor.reconnectAttempt == 0
        }
        XCTAssertTrue(restored, "reconnect should restore the connection and reset the attempt counter")
        XCTAssertEqual(relay.reconnectCallCount, 1)
    }

    func testBackoffDelaysGrowExponentiallyWhileRelayStaysDown() async {
        let monitor = ConnectionMonitorModel(relay: flaky, sleeper: sleeper)
        defer { monitor.stop() }
        monitor.start()
        flaky.push(.connected)
        _ = await TestSupport.waitUntil { monitor.state.isConnected }

        flaky.reconnectOutcome = .disconnected(reason: "Mac offline")
        flaky.push(.disconnected(reason: "Mac offline"))
        _ = await TestSupport.waitUntil { self.sleeper.recorded.count == 1 }
        sleeper.releaseNext()
        _ = await TestSupport.waitUntil { self.sleeper.recorded.count == 2 }
        sleeper.releaseNext()
        let backedOff = await TestSupport.waitUntil { self.sleeper.recorded.count == 3 }
        XCTAssertTrue(backedOff, "at least three backoff sleeps should happen while offline")
        guard backedOff else { return }

        let seconds = sleeper.recorded.prefix(3).map { duration in
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        XCTAssertEqual(seconds[0], 0.5, accuracy: 0.001, "first retry waits the base delay")
        XCTAssertEqual(seconds[1], 1.0, accuracy: 0.001, "second retry doubles")
        XCTAssertEqual(seconds[2], 2.0, accuracy: 0.001, "third retry doubles again")
    }

    func testReconnectNowResetsAttemptsAndCallsRelay() async {
        let monitor = ConnectionMonitorModel(relay: flaky, sleeper: sleeper)
        defer { monitor.stop() }
        monitor.start()
        flaky.reconnectOutcome = .connected
        flaky.push(.disconnected(reason: "away"))
        _ = await TestSupport.waitUntil { self.sleeper.recorded.count == 1 }
        XCTAssertEqual(flaky.reconnectCount, 0)

        await monitor.reconnectNow()
        _ = await TestSupport.waitUntil { monitor.state.isConnected }
        XCTAssertEqual(flaky.reconnectCount, 1)
        XCTAssertEqual(monitor.reconnectAttempt, 0)
    }

    func testConnectedEventsReplayCurrentState() async {
        let monitor = ConnectionMonitorModel(relay: relay, sleeper: sleeper)
        defer { monitor.stop() }
        monitor.start()
        _ = await TestSupport.waitUntil { monitor.state.isConnected }

        let expectation = expectation(description: "replayed connected value arrives")
        let task = Task {
            for await connected in monitor.connectedEvents() where connected {
                expectation.fulfill()
                break
            }
        }
        await fulfillment(of: [expectation], timeout: 2)
        task.cancel()
    }

    func testStopCancelsReconnectLoop() async {
        let monitor = ConnectionMonitorModel(relay: flaky, sleeper: sleeper)
        defer { monitor.stop() }
        monitor.start()
        flaky.push(.disconnected(reason: "down"))
        _ = await TestSupport.waitUntil { self.sleeper.recorded.count == 1 }
        sleeper.releaseNext()
        _ = await TestSupport.waitUntil { self.sleeper.recorded.count == 2 }

        monitor.stop()
        let attemptCount = monitor.reconnectAttempt
        await TestSupport.drainMainActor()
        XCTAssertLessThanOrEqual(
            monitor.reconnectAttempt,
            attemptCount,
            "attempts should stop climbing after stop()"
        )
    }

    func testStopIgnoresAlreadyBufferedConnectionEvent() async {
        let monitor = ConnectionMonitorModel(relay: flaky, sleeper: sleeper)
        monitor.start()
        flaky.push(.connected)
        _ = await TestSupport.waitUntil { monitor.state.isConnected }
        flaky.push(.disconnected(reason: "buffered before stop"))
        monitor.stop()
        await TestSupport.drainMainActor()
        XCTAssertTrue(monitor.state.isConnected)
        XCTAssertTrue(sleeper.recorded.isEmpty)
        XCTAssertEqual(flaky.reconnectCount, 0)
    }

    func testConnectedEventsDoNotFeedBackFromSuccessfulRefreshes() async {
        let monitor = ConnectionMonitorModel(relay: relay, sleeper: sleeper)
        monitor.start()
        defer { monitor.stop() }
        _ = await TestSupport.waitUntil { monitor.state.isConnected }
        var observed: [Bool] = []
        let observer = Task {
            for await connected in monitor.connectedEvents() {
                guard !Task.isCancelled else { break }
                observed.append(connected)
                if connected {
                    // Production projects RPCs report connected on success.
                    relay.pushConnection(.connected)
                }
            }
        }
        defer { observer.cancel() }
        _ = await TestSupport.waitUntil { observed == [true] }
        await TestSupport.drainMainActor()
        XCTAssertEqual(observed, [true], "a refresh must not recursively trigger another refresh")
        relay.pushConnection(.disconnected(reason: "offline"))
        _ = await TestSupport.waitUntil { observed == [true, false] }
        relay.pushConnection(.disconnected(reason: "still offline"))
        _ = await TestSupport.waitUntil { monitor.state == .disconnected(reason: "still offline") }
        XCTAssertEqual(observed, [true, false], "reason changes must not rebroadcast connectivity")
        relay.pushConnection(.connected)
        _ = await TestSupport.waitUntil { observed == [true, false, true] }
        await TestSupport.drainMainActor()
        XCTAssertEqual(observed, [true, false, true])
    }
}

final class ReconnectPolicyTests: XCTestCase {
    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    func testDelayGrowsExponentiallyAndCaps() {
        let policy = ReconnectPolicy() // 0.5s base, ×2, 30s cap

        var expected = 0.5
        for attempt in 1...7 {
            XCTAssertEqual(seconds(policy.delay(afterAttempt: attempt, jitter: 0)), expected, accuracy: 0.001)
            expected = min(expected * 2, 30)
        }

        XCTAssertEqual(
            seconds(policy.delay(afterAttempt: 40, jitter: 0)),
            30,
            accuracy: 0.001,
            "the schedule is capped at maxDelay"
        )
    }

    func testJitterStaysWithinBounds() {
        let policy = ReconnectPolicy()
        let base = seconds(policy.delay(afterAttempt: 3, jitter: 0))

        for _ in 0..<50 {
            let jittered = seconds(policy.delay(afterAttempt: 3, jitter: 0.4))
            XCTAssertGreaterThanOrEqual(jittered, base * 0.6 - 0.001)
            XCTAssertLessThanOrEqual(jittered, base * 1.4 + 0.001)
        }
    }

    func testCustomPolicy() {
        let policy = ReconnectPolicy(
            baseDelay: .seconds(10),
            maxDelay: .seconds(60),
            multiplier: 3
        )
        XCTAssertEqual(policy.delay(afterAttempt: 1, jitter: 0), .seconds(10))
        XCTAssertEqual(policy.delay(afterAttempt: 2, jitter: 0), .seconds(30))
        XCTAssertEqual(policy.delay(afterAttempt: 3, jitter: 0), .seconds(60), "capped at max")
    }
}
