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

@MainActor
final class ConnectionMonitorTests: XCTestCase {
    private var relay: ScriptedRelay!
    private var flaky: FlakyRelay!
    private var sleeper: RecordedSleeper!

    override func setUp() {
        super.setUp()
        relay = PreviewData.scriptedRelay()
        flaky = FlakyRelay()
        sleeper = RecordedSleeper()
    }

    func testStartPicksUpReplayedConnectionState() async {
        let monitor = ConnectionMonitorModel(relay: relay, sleeper: sleeper)
        XCTAssertEqual(monitor.state, .initial)
        monitor.start()
        let connected = await TestSupport.waitUntil { monitor.state.isConnected }
        XCTAssertTrue(connected, "the relay's replayed connected state should apply immediately")
    }

    func testDisconnectSchedulesBackoffReconnect() async {
        let monitor = ConnectionMonitorModel(relay: relay, sleeper: sleeper)
        monitor.start()
        _ = await TestSupport.waitUntil { monitor.state.isConnected }

        relay.pushConnection(.disconnected(reason: "link dropped"))
        let scheduled = await TestSupport.waitUntil {
            monitor.reconnectAttempt >= 1 && !sleeper.recorded.isEmpty
        }
        XCTAssertTrue(scheduled, "a disconnect should schedule the first backoff attempt")
        XCTAssertFalse(monitor.state.isConnected)

        // The scripted relay reconnects instantly; the monitor should settle
        // back to connected and stop the loop.
        let restored = await TestSupport.waitUntil {
            monitor.state.isConnected && monitor.reconnectAttempt == 0
        }
        XCTAssertTrue(restored, "reconnect should restore the connection and reset the attempt counter")
        XCTAssertEqual(relay.reconnectCallCount, 1)
    }

    func testBackoffDelaysGrowExponentiallyWhileRelayStaysDown() async {
        let monitor = ConnectionMonitorModel(relay: flaky, sleeper: sleeper)
        monitor.start()
        flaky.push(.connected)
        _ = await TestSupport.waitUntil { monitor.state.isConnected }

        flaky.reconnectOutcome = .disconnected(reason: "Mac offline")
        flaky.push(.disconnected(reason: "Mac offline"))
        let backedOff = await TestSupport.waitUntil { sleeper.recorded.count >= 3 }
        XCTAssertTrue(backedOff, "at least three backoff sleeps should happen while offline")

        let seconds = sleeper.recorded.prefix(3).map { duration in
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        XCTAssertEqual(seconds[0], 0.5, accuracy: 0.001, "first retry waits the base delay")
        XCTAssertEqual(seconds[1], 1.0, accuracy: 0.001, "second retry doubles")
        XCTAssertEqual(seconds[2], 2.0, accuracy: 0.001, "third retry doubles again")
    }

    func testReconnectNowResetsAttemptsAndCallsRelay() async {
        let monitor = ConnectionMonitorModel(relay: flaky, sleeper: sleeper)
        monitor.start()
        flaky.reconnectOutcome = .connected
        flaky.push(.disconnected(reason: "away"))
        _ = await TestSupport.waitUntil { monitor.reconnectAttempt >= 1 }

        await monitor.reconnectNow()

        XCTAssertEqual(flaky.reconnectCount, 1)
        XCTAssertEqual(monitor.reconnectAttempt, 0)
    }

    func testConnectedEventsReplayCurrentState() async {
        let monitor = ConnectionMonitorModel(relay: relay, sleeper: sleeper)
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
        monitor.start()
        flaky.push(.disconnected(reason: "down"))
        _ = await TestSupport.waitUntil { monitor.reconnectAttempt >= 2 }

        monitor.stop()
        let attemptCount = monitor.reconnectAttempt
        await TestSupport.drainMainActor()
        XCTAssertLessThanOrEqual(
            monitor.reconnectAttempt,
            attemptCount,
            "attempts should stop climbing after stop()"
        )
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
