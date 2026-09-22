import XCTest
@testable import Skynet

/// Behavioral tests for the session view model: event folding, permissions,
/// queueing, notifications, and lifecycle. Everything runs against the
/// scripted relay with deterministic fixtures.
@MainActor
final class SessionViewModelTests: XCTestCase {
    private var relay: ScriptedRelay!
    private var scheduler: RecordingNotificationScheduler!
    private var activityState: AppActivityState!
    private var monitor: ConnectionMonitorModel!
    private var model: SessionViewModel!

    private let session = PreviewData.idleSession

    override func setUp() {
        super.setUp()
        relay = PreviewData.scriptedRelay()
        scheduler = RecordingNotificationScheduler()
        activityState = AppActivityState()
        // Long delays keep the auto-reconnect loop out of the test's way;
        // tests drive connection state explicitly.
        monitor = ConnectionMonitorModel(
            relay: relay,
            policy: ReconnectPolicy(baseDelay: .seconds(3600), maxDelay: .seconds(7200), multiplier: 1)
        )
        monitor.start()
        model = SessionViewModel(
            session: session,
            relay: relay,
            monitor: monitor,
            notifications: scheduler,
            liveActivities: NoopLiveActivityPresenter(),
            activityState: activityState
        )
    }

    private func startAndWaitForSnapshot() async {
        model.start()
        let loaded = await TestSupport.waitUntil {
            !self.model.isLoadingSnapshot && !self.model.items.isEmpty
        }
        XCTAssertTrue(loaded, "snapshot should load")
    }

    // MARK: - Snapshot & streaming

    func testStartLoadsSnapshotAndModelCatalog() async {
        await startAndWaitForSnapshot()

        XCTAssertEqual(model.items.count, PreviewData.transcript.count)
        XCTAssertEqual(model.currentSession.id, session.id)
        XCTAssertEqual(
            model.availableModels.map(\.id),
            AgentModel.defaultCatalog.map(\.id)
        )
    }

    func testMessageDeltasAppendIntoStreamingMessage() async {
        await startAndWaitForSnapshot()
        let liveID = TranscriptItemID("t-live")

        relay.emitItem(
            .assistantMessage(AssistantMessage(id: liveID, text: "", isStreaming: true)),
            to: session.id
        )
        relay.emit(.messageDelta(itemID: liveID, text: "Hello "), to: session.id)
        relay.emit(.messageDelta(itemID: liveID, text: "world"), to: session.id)

        let folded = await TestSupport.waitUntil {
            self.model.items.contains {
                if case .assistantMessage(let message) = $0 {
                    return message.id == liveID && message.text == "Hello world" && message.isStreaming
                }
                return false
            }
        }
        XCTAssertTrue(folded, "deltas should fold into one streaming message")

        relay.emit(.messageCompleted(itemID: liveID), to: session.id)
        let completed = await TestSupport.waitUntil {
            self.model.items.contains {
                if case .assistantMessage(let message) = $0 {
                    return message.id == liveID && !message.isStreaming
                }
                return false
            }
        }
        XCTAssertTrue(completed, "message should stop streaming")
    }

    func testDeltaWithoutAppendCreatesMessage() async {
        await startAndWaitForSnapshot()
        let orphanID = TranscriptItemID("t-orphan")

        relay.emit(.messageDelta(itemID: orphanID, text: "materialized"), to: session.id)

        let created = await TestSupport.waitUntil {
            self.model.items.contains { $0.id == orphanID }
        }
        XCTAssertTrue(created, "orphan deltas should materialize a streaming message")
    }

    func testToolCallUpdateReplacesInPlace() async {
        await startAndWaitForSnapshot()
        let existing = PreviewData.transcript[3]
        guard case .toolCall(let original) = existing else {
            return XCTFail("fixture mismatch")
        }

        var failed = original
        failed.state = .failed
        failed.output = "command not found"
        failed.finishedAt = original.startedAt.addingTimeInterval(4)
        relay.emit(.toolCallUpdated(failed), to: session.id)

        let replaced = await TestSupport.waitUntil {
            self.model.items.count == PreviewData.transcript.count
                && self.model.items.contains {
                    if case .toolCall(let call) = $0 {
                        return call.id == original.id && call.state == .failed
                    }
                    return false
                }
        }
        XCTAssertTrue(replaced, "tool call should update in place, not append")
    }

    // MARK: - Permissions

    func testReadScopeAutoApprovesUnderAskForWrites() async {
        await startAndWaitForSnapshot()
        let request = PermissionRequestRecord(
            id: TranscriptItemID("perm-read"),
            summary: "Read Package.swift",
            scope: .read
        )
        relay.emit(.permissionUpdated(request), to: session.id)

        let resolved = await TestSupport.waitUntil {
            self.relay.permissionDecisions.contains { $0.requestID == request.id }
        }
        XCTAssertTrue(resolved, "read scope should auto-approve under askForWrites")
    }

    func testWriteScopeAsksAndNotifiesWhenInactive() async {
        await startAndWaitForSnapshot()
        activityState.isSceneActive = false

        let request = PermissionRequestRecord(
            id: TranscriptItemID("perm-write"),
            summary: "Edit Package.swift",
            scope: .write
        )
        relay.emit(.permissionUpdated(request), to: session.id)

        let notified = await TestSupport.waitUntil { !self.scheduler.scheduled.isEmpty }
        XCTAssertTrue(notified, "a pending write request should notify while the app is inactive")
        XCTAssertEqual(scheduler.scheduled.first?.body, request.summary)

        let stillPending = await TestSupport.waitUntil {
            self.model.items.contains {
                if case .permissionRequest(let record) = $0 {
                    return record.id == request.id && record.isPending
                }
                return false
            }
        }
        XCTAssertTrue(stillPending, "write requests must not auto-approve")
    }

    func testResolveRecordsDecisionAndAlwaysEscalatesMode() async {
        await startAndWaitForSnapshot()
        guard case .permissionRequest(let request) = PreviewData.transcript[5] else {
            return XCTFail("fixture mismatch")
        }

        await model.resolve(request, decision: .approvedAlways)

        XCTAssertEqual(
            relay.permissionDecisions.map(\.decision),
            [.approvedAlways]
        )
        XCTAssertEqual(
            relay.configurationUpdates.map(\.configuration.permissions),
            [.autonomous],
            "always-allow should escalate the session to autonomous"
        )
        XCTAssertEqual(model.currentSession.configuration.permissions, .autonomous)
    }

    // MARK: - Sending & queueing

    func testSendWhenIdleAndConnectedReachesRelayWithoutLocalEcho() async {
        await startAndWaitForSnapshot()
        let itemCount = model.items.count

        await model.send(PromptPayload(text: "Run the suite"))

        XCTAssertEqual(relay.sentPrompts.map(\.payload.text), ["Run the suite"])
        XCTAssertEqual(model.items.count, itemCount, "no local echo — the relay owns the transcript")
        XCTAssertTrue(model.queue.isEmpty)
    }

    func testSendWhileBusyQueuesWithTurnBusyReason() async {
        await startAndWaitForSnapshot()
        relay.emit(.turnStateChanged(.running), to: session.id)
        _ = await TestSupport.waitUntil { self.model.currentTurnState == .running }

        await model.send(PromptPayload(text: "next task"))

        XCTAssertEqual(model.queuedPrompts.first?.reason, .turnBusy)
        XCTAssertTrue(relay.sentPrompts.isEmpty)
    }

    func testSendOfflineQueuesWithOfflineReason() async {
        await startAndWaitForSnapshot()
        relay.pushConnection(.disconnected(reason: "Mac asleep"))
        _ = await TestSupport.waitUntil { !self.model.currentConnectionState.isConnected }

        await model.send(PromptPayload(text: "later"))

        XCTAssertEqual(model.queuedPrompts.first?.reason, .offline)
        XCTAssertTrue(relay.sentPrompts.isEmpty)
    }

    func testFailedSendQueuesForRetry() async {
        await startAndWaitForSnapshot()
        relay.promptError = SkynetError.connectionLost("offline")

        await model.send(PromptPayload(text: "will fail"))

        XCTAssertNotNil(model.errorBanner)
        XCTAssertEqual(model.queuedPrompts.first?.reason, .offline)
    }

    func testQueueFlushesWhenTurnGoesIdle() async {
        await startAndWaitForSnapshot()
        relay.emit(.turnStateChanged(.running), to: session.id)
        _ = await TestSupport.waitUntil { !self.model.currentTurnState.acceptsNewPrompt }

        await model.send(PromptPayload(text: "queued while busy"))
        XCTAssertEqual(model.queuedPromptCount, 1)

        relay.emit(.turnStateChanged(.idle), to: session.id)
        let flushed = await TestSupport.waitUntil { self.model.queue.isEmpty }
        XCTAssertTrue(flushed, "queue should flush once the turn is idle")
        XCTAssertEqual(relay.sentPrompts.map(\.payload.text), ["queued while busy"])
    }

    func testQueueFlushesOnReconnect() async {
        await startAndWaitForSnapshot()
        relay.pushConnection(.disconnected(reason: "away"))
        _ = await TestSupport.waitUntil { !self.model.currentConnectionState.isConnected }

        await model.send(PromptPayload(text: "queued offline"))
        XCTAssertEqual(model.queuedPromptCount, 1)

        relay.pushConnection(.connected)
        let flushed = await TestSupport.waitUntil { self.model.queue.isEmpty }
        XCTAssertTrue(flushed, "queue should flush on reconnect")
        XCTAssertEqual(relay.sentPrompts.map(\.payload.text), ["queued offline"])
    }

    func testExplicitQueueAndSendNowBypassOrder() async {
        await startAndWaitForSnapshot()
        relay.emit(.turnStateChanged(.running), to: session.id)
        _ = await TestSupport.waitUntil { !self.model.currentTurnState.acceptsNewPrompt }

        model.composerDidRequestQueue(PromptPayload(text: "first"))
        model.composerDidRequestQueue(PromptPayload(text: "second"))
        XCTAssertEqual(model.queuedPromptCount, 2)

        // "Send now" runs immediately, even mid-turn (explicit user intent).
        let second = model.queuedPrompts[1]
        model.composerDidRequestSendQueuedPrompt(id: second.id)
        let sent = await TestSupport.waitUntil {
            self.relay.sentPrompts.contains { $0.payload.text == "second" }
        }
        XCTAssertTrue(sent)
        XCTAssertEqual(model.queuedPromptCount, 1, "only the sent entry leaves the queue")

        model.composerDidRequestRemoveQueuedPrompt(id: model.queuedPrompts[0].id)
        XCTAssertTrue(model.queue.isEmpty)
    }

    // MARK: - Session controls

    func testRenameUpdatesRelayAndLocalTitle() async {
        await startAndWaitForSnapshot()
        await model.rename(to: "  Fresh Title  ")

        XCTAssertEqual(relay.renameCalls.map(\.title), ["Fresh Title"])
        XCTAssertEqual(model.currentSession.title, "Fresh Title")
    }

    func testRenameIgnoresEmptyAndDuplicateTitles() async {
        await startAndWaitForSnapshot()
        await model.rename(to: "   ")
        await model.rename(to: session.title)
        XCTAssertTrue(relay.renameCalls.isEmpty)
    }

    func testCancelTurnForwardsToRelay() async {
        await startAndWaitForSnapshot()
        relay.emit(.turnStateChanged(.running), to: session.id)
        _ = await TestSupport.waitUntil { self.model.currentTurnState.isBusy }

        await model.cancelTurn()

        XCTAssertEqual(relay.cancelCalls, [session.id])
    }

    func testConfigurationChangeForwardsToRelay() async {
        await startAndWaitForSnapshot()
        model.composerDidChangeConfiguration(
            AgentConfiguration(model: .deep, effort: .thorough, permissions: .autonomous)
        )

        let applied = await TestSupport.waitUntil {
            self.model.currentConfiguration.permissions == .autonomous
        }
        XCTAssertTrue(applied)
        XCTAssertEqual(
            relay.configurationUpdates.map(\.configuration.model),
            [.deep]
        )
    }

    // MARK: - Unread & visibility

    func testUnreadCountsOnlyWhileInvisible() async {
        await startAndWaitForSnapshot()
        model.setViewVisible(false)

        relay.emitItem(
            .userMessage(UserMessage(id: TranscriptItemID("t-new-user"), text: "from the Mac")),
            to: session.id
        )
        let counted = await TestSupport.waitUntil { self.model.unreadCount == 1 }
        XCTAssertTrue(counted, "events while hidden should count as unread")

        model.setViewVisible(true)
        XCTAssertEqual(model.unreadCount, 0)
    }

    func testSessionRenamedEventUpdatesTitle() async {
        await startAndWaitForSnapshot()
        relay.emit(.sessionRenamed("Renamed on Mac"), to: session.id)

        let updated = await TestSupport.waitUntil { self.model.currentSession.title == "Renamed on Mac" }
        XCTAssertTrue(updated)
    }
}
