import Foundation
import SkynetCore
import SwiftUI

// Only the actual AppModel permission and Stop methods are inserted. No app,
// account store, real provider process, or security setting is used by this fixture.
// Integration cases use the real AgentSession and scripted protocol processes.
@MainActor
final class PermissionHarness {
    var selectedSessionID: SessionID?
    var scheduledDispatchSessionID: SessionID?
    var activeTurnSessionID: SessionID?
    var scheduledSession: AgentSession?
    var activeSession: AgentSession?
    var scheduledDispatch: Task<Void, Never>?
    var streamTask: Task<Void, Never>?
    var pendingPermissionRequest: PermissionRequest?
    var pendingPermissionSessionTitle: String?
    var pendingPermissionSessionID: SessionID?
    var permissionContinuation: CheckedContinuation<PermissionResponse, Never>?
    var permissionRequestToken: UUID?
    var responses: [PermissionResponse] = []
    var events: [AgentEvent] = []
    var consumerFinished = false
    var consumerError: String?

    func decide(_ request: PermissionRequest, title: String?) async -> PermissionResponse {
        // Do not create another Task here: cancellation must reach the real
        // responder task suspended in the production continuation.
        let response = await requestPermission(request, sessionID: request.sessionID, sessionTitle: title)
        responses.append(response)
        return response
    }

    func consume(_ stream: AsyncThrowingStream<AgentEvent, Error>) -> Task<Void, Never> {
        Task {
            do { for try await event in stream { events.append(event) } }
            catch { consumerError = String(describing: error) }
            consumerFinished = true
        }
    }

    func present(_ request: PermissionRequest, title: String? = nil) -> Task<PermissionResponse, Never> {
        Task {
            let response = await requestPermission(request, sessionID: request.sessionID, sessionTitle: title)
            responses.append(response)
            return response
        }
    }
    func replaceAfterCancelling(
        _ old: Task<PermissionResponse, Never>, with request: PermissionRequest
    ) -> Task<PermissionResponse, Never> {
        Task {
            old.cancel()
            let response = await requestPermission(request, sessionID: request.sessionID)
            responses.append(response)
            return response
        }
    }
    // PRODUCTION_PERMISSION_METHODS
}

// PRODUCTION_RESPONDER

@MainActor
private struct PermissionPresentationHarness {
    let model: PermissionHarness
    // PRODUCTION_PERMISSION_PRESENTATION_BINDING
}

@main
@MainActor
enum PermissionRequestCancellationRegression {
    private enum StopPath: String, CaseIterable {
        case actor, composer, permissionCard
    }
    static func main() async {
        do { try await verify() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    private static func protocolScript(codex: Bool, recovery: Bool = false) -> ScriptedExecutionBackend.Script {
        if !codex {
            if recovery {
                return .init(stdoutLines: [
                    #"{"type":"assistant","message":{"id":"owned-answer","role":"assistant","content":[{"type":"text","text":"OWN_RECOVERY_OK"}]}}"#,
                    #"{"type":"result","subtype":"success","result":"OWN_RECOVERY_OK","session_id":"fixture-recovery"}"#,
                ])
            }
            return .init(onStdin: { data, process in
                guard let frame = try? JSONDecoder().decode(JSONValue.self, from: data),
                      frame["type"]?.stringValue == "user" else { return }
                process.emitStdout(#"{"type":"control_request","request_id":"integration-ask","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"/bin/echo NOT_EXECUTED"}}}"#)
                // Both streams stay open until owned cancellation. No actual
                // command, success frame or automatic EOF can end this turn.
            })
        }
        return .init(onStdin: { data, process in
            let methods = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
                try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
            }.compactMap { $0["method"]?.stringValue }
            if methods.contains("initialize") {
                process.emitStdout(#"{"id":0,"result":{}}"#)
            } else if methods.contains("thread/start") || methods.contains("thread/resume") {
                process.emitStdout(#"{"id":1,"result":{"thread":{"id":"owned-fixture-thread"}}}"#)
            } else if methods.contains("turn/start") {
                process.emitStdout(#"{"id":2,"result":{"turn":{"id":"owned-fixture-turn"}}}"#)
                if recovery {
                    process.emitStdout(#"{"method":"item/completed","params":{"item":{"id":"owned-answer","type":"agentMessage","text":"OWN_RECOVERY_OK"}}}"#)
                    process.emitStdout(#"{"method":"turn/completed","params":{"turn":{"status":"completed"}}}"#)
                    process.finishStdout()
                } else {
                    process.emitStdout(#"{"id":17,"method":"item/commandExecution/requestApproval","params":{"threadId":"owned-fixture-thread","turnId":"owned-fixture-turn","itemId":"owned-command","command":"/bin/echo NOT_EXECUTED","reason":"Offline fixture"}}"#)
                }
            }
        })
    }

    static func verify() async throws {
        var failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            print("\(value ? "PASS" : "FAIL"): \(label)")
            if !value { failures.append(label) }
        }
        func request(_ id: String, _ session: SessionID) -> PermissionRequest {
            .init(id: id, sessionID: session, toolName: "owned-fixture-tool", summary: "No real tool")
        }
        func settle() async {
            for _ in 0..<30 { try? await Task.sleep(for: .milliseconds(5)) }
        }
        func waitUntil(_ predicate: () async -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(3)
            while !(await predicate()), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return await predicate()
        }
        func completions(_ events: [AgentEvent]) -> [TurnSummary] {
            events.compactMap { event in
                if case .turnCompleted(let summary) = event { return summary }
                return nil
            }
        }
        let own = SessionID(), other = SessionID()

        for scheduled in [false, true] {
            let model = PermissionHarness()
            model.selectedSessionID = own
            if scheduled { model.scheduledDispatchSessionID = own }
            else { model.activeTurnSessionID = own }
            let pending = model.present(request("own-\(scheduled)", own), title: scheduled ? "Own schedule" : nil)
            await settle()
            check(model.pendingPermissionSessionID == own,
                  "actual request stores \(scheduled ? "scheduled" : "ordinary") ownership")
            model.cancel()
            let response = await pending.value
            check(response.requestID == "own-\(scheduled)" && response.decision == .deny,
                  "actual Stop resolves only its own \(scheduled ? "scheduled" : "ordinary") continuation")
            check(model.pendingPermissionRequest == nil && model.pendingPermissionSessionID == nil
                  && model.pendingPermissionSessionTitle == nil && model.permissionContinuation == nil
                  && model.permissionRequestToken == nil,
                  "actual answer clears request/owner/title/continuation")

            let unrelated = model.present(request("unrelated-\(scheduled)", other))
            await settle()
            model.cancel()
            await settle()
            check(model.pendingPermissionRequest?.id == "unrelated-\(scheduled)"
                  && model.responses.count == 1 && !model.canStopPermissionTurn,
                  "\(scheduled ? "scheduled" : "ordinary") Stop leaves another own fixture session awaiting its answer")
            model.answerPermission(.allow)
            let allowed = await unrelated.value
            check(allowed.decision == .allow && allowed.requestID == "unrelated-\(scheduled)",
                  "unrelated request can still receive its exact explicit answer")

            model.selectedSessionID = other
            let card = model.present(request("background-card-\(scheduled)", own))
            await settle()
            model.cancel() // Selected session is not the request/turn owner.
            await settle()
            check(model.canStopPermissionTurn && model.pendingPermissionSessionID == own
                  && model.responses.count == 2,
                  "\(scheduled ? "scheduled" : "ordinary") composer Stop cannot cancel a different selected fixture session")
            model.permissionTurnStopAction?()
            let cardReply = await card.value
            check(cardReply.decision == .deny && !model.canStopPermissionTurn
                  && model.pendingPermissionRequest == nil && model.responses.count == 3,
                  "\(scheduled ? "scheduled" : "ordinary") permission-card Stop targets its owner, not the selected session")
        }

        let late = PermissionHarness()
        let beforeEntry = late.present(request("already-cancelled", own))
        beforeEntry.cancel() // MainActor task has not entered actual request method.
        await settle()
        check(late.pendingPermissionRequest == nil && late.responses.count == 1,
              "cancelled provider task cannot publish a late permission card")
        if late.pendingPermissionRequest != nil { late.answerPermission(.deny) } // Baseline-only containment.
        let earlyResponse = await beforeEntry.value
        check(earlyResponse.decision == .deny, "cancelled pre-entry request resolves with denial")

        let suspended = PermissionHarness()
        let waiting = suspended.present(request("cancel-while-waiting", own))
        await settle()
        check(suspended.pendingPermissionRequest?.id == "cancel-while-waiting", "actual pending continuation is established")
        waiting.cancel()
        await settle()
        check(suspended.pendingPermissionRequest == nil && suspended.responses.count == 1,
              "provider cancellation releases its actual suspended permission continuation")
        if suspended.pendingPermissionRequest != nil { suspended.answerPermission(.deny) }
        _ = await waiting.value

        let replaced = PermissionHarness()
        let old = replaced.present(request("reused-provider-id", own))
        await settle()
        let new = replaced.present(request("reused-provider-id", other), title: "New own fixture session")
        await settle()
        let superseded = await old.value
        check(superseded.decision == .deny && superseded.reason?.contains("replaced") == true,
              "new request resolves the actual previous continuation before replacing it")
        old.cancel()
        await settle()
        check(replaced.pendingPermissionSessionID == other && replaced.responses.count == 1,
              "old cancellation cannot answer replacement with the same provider request ID")
        replaced.answerPermission(.allowAlways)
        let replacement = await new.value
        check(replacement.decision == .allowAlways && replacement.requestID == "reused-provider-id",
              "replacement receives its exact answer without persistent system grants")

        let racing = PermissionHarness()
        let previous = racing.present(request("same-session-reused-id", own))
        await settle()
        let previousToken = racing.permissionRequestToken
        let next = racing.replaceAfterCancelling(previous, with: request("same-session-reused-id", own))
        await settle()
        _ = await previous.value
        check(racing.pendingPermissionRequest?.id == "same-session-reused-id"
              && racing.pendingPermissionSessionID == own && racing.responses.count == 1
              && racing.permissionRequestToken != previousToken,
              "stale cancellation cannot deny a new continuation with the same session and request ID")
        racing.answerPermission(.allow)
        let raceReply = await next.value
        check(raceReply.decision == .allow && racing.responses.count == 2,
              "replacement and cancelled continuations each resume exactly once")

        let staleCard = PermissionHarness()
        staleCard.activeTurnSessionID = own
        let originalConsumer = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        staleCard.streamTask = originalConsumer
        let oldCard = staleCard.present(request("same-card-id", own))
        await settle()
        let capturedStop = staleCard.permissionTurnStopAction
        staleCard.answerPermission(.deny)
        _ = await oldCard.value
        let replacementConsumer = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        staleCard.streamTask = replacementConsumer
        let nextCard = staleCard.present(request("same-card-id", own))
        await settle()
        capturedStop?()
        await settle()
        check(originalConsumer.isCancelled && !replacementConsumer.isCancelled,
              "captured modal Stop cancels its exact old consumer, not a replacement with the same session")
        check(staleCard.pendingPermissionRequest?.id == "same-card-id" && staleCard.responses.count == 1,
              "captured modal Stop cannot deny a newer same-session/same-ID permission generation")
        staleCard.answerPermission(.allow)
        let nextCardReply = await nextCard.value
        check(nextCardReply.decision == .allow && staleCard.responses.count == 2,
              "replacement permission remains independently answerable after a stale modal action")
        replacementConsumer.cancel()
        await originalConsumer.value
        await replacementConsumer.value

        for decision in [PermissionResponse.Decision.allow, .allowAlways, .deny] {
            let staleDecision = PermissionHarness()
            let firstDecision = staleDecision.present(request("reused-decision-id", own))
            await settle()
            let firstDecisionToken = staleDecision.permissionRequestToken
            // PRODUCTION_PERMISSION_DECISION_BINDING
            let secondDecision = staleDecision.present(request("reused-decision-id", own))
            await settle()
            let firstDecisionReply = await firstDecision.value
            check(firstDecisionReply.decision == .deny
                  && staleDecision.permissionRequestToken != firstDecisionToken,
                  "\(decision): actual replacement denies the old continuation and changes generation")
            capturedDecision(decision)
            await settle()
            check(staleDecision.pendingPermissionRequest != nil && staleDecision.responses.count == 1,
                  "\(decision): captured real sheet answer cannot resolve a newer same-session/same-ID request")
            // Fixture-only cleanup/current answer, AFTER the isolation assertion.
            staleDecision.answerPermission(.deny)
            let secondDecisionReply = await secondDecision.value
            check(secondDecisionReply.decision == .deny && staleDecision.responses.count == 2,
                  "\(decision): replacement remains independently answerable exactly once")
        }

        let staleDecision = PermissionHarness()
        // PRODUCTION_PERMISSION_DECISION_BINDING
        let futureDecision = staleDecision.present(request("future-decision-id", own))
        await settle()
        capturedDecision(.allow)
        await settle()
        check(staleDecision.pendingPermissionRequest?.id == "future-decision-id"
              && staleDecision.responses.isEmpty,
              "a callback captured with no request cannot answer a future permission")
        staleDecision.answerPermission(.deny)
        let futureDecisionReply = await futureDecision.value
        check(futureDecisionReply.decision == .deny && staleDecision.responses.count == 1,
              "the future permission remains answerable exactly once")

        let dismissal = PermissionHarness()
        let dismissalView = PermissionPresentationHarness(model: dismissal)
        let firstDismissal = dismissal.present(request("reused-dismissal-id", own))
        await settle()
        let oldPresentation = dismissalView.permissionDialogPresented
        oldPresentation.wrappedValue = true
        await settle()
        check(dismissal.pendingPermissionRequest != nil && dismissal.responses.isEmpty,
              "presenting the actual binding does not answer its request")
        let nextDismissal = dismissal.present(request("reused-dismissal-id", own))
        await settle()
        _ = await firstDismissal.value
        oldPresentation.wrappedValue = false
        await settle()
        check(dismissal.pendingPermissionRequest != nil && dismissal.responses.count == 1,
              "old presentation dismissal cannot deny a newer same-session/same-ID request")
        dismissalView.permissionDialogPresented.wrappedValue = false
        let nextDismissalReply = await nextDismissal.value
        check(nextDismissalReply.decision == .deny && dismissal.responses.count == 2,
              "current presentation dismissal denies exactly its own continuation")

        let emptyPresentation = dismissalView.permissionDialogPresented
        let futureDismissal = dismissal.present(request("future-dismissal-id", own))
        await settle()
        emptyPresentation.wrappedValue = false
        await settle()
        check(dismissal.pendingPermissionRequest != nil && dismissal.responses.count == 2,
              "a no-request presentation dismissal cannot deny a future permission")
        dismissalView.permissionDialogPresented.wrappedValue = false
        _ = await futureDismissal.value

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skynet-permission-chain-\(UUID().uuidString)")
        let store = try JSONDiskStore(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }
        for codex in [false, true] {
          for scheduled in [false, true] {
            for stop in StopPath.allCases {
                let label = "\(codex ? "Codex app-server" : "Claude stream-json")/\(scheduled ? "scheduled" : "ordinary")/\(stop.rawValue)"
                let model = PermissionHarness()
                let provider = codex ? AgentProviderDescriptor.codex : .claudeCode
                let record = SessionRecord(projectID: ProjectID(), providerID: provider.id,
                                           codexApprovalMode: codex ? .manual : nil)
                model.selectedSessionID = record.id
                let backend = ScriptedExecutionBackend(scripts: [protocolScript(codex: codex)])
                let session = try AgentSession(record: record, configuration: .init(
                    provider: provider, backend: backend, policy: .macOS,
                    permissions: .askEverything,
                    permissionResponder: AppPermissionResponder { request in
                        await model.decide(request, title: scheduled ? "Own schedule" : nil)
                    }, store: store
                ))
                if scheduled {
                    model.scheduledDispatchSessionID = record.id
                    model.scheduledSession = session
                } else {
                    model.activeTurnSessionID = record.id
                    model.activeSession = session
                }
                let stream = try await session.send("offline owned permission cancellation")
                let consumer = model.consume(stream)
                if scheduled { model.scheduledDispatch = consumer }
                else { model.streamTask = consumer }
                let requestID = codex ? "17" : "integration-ask"
                let presented = await waitUntil { model.pendingPermissionRequest?.id == requestID }
                check(presented && model.pendingPermissionSessionID == record.id && model.canStopPermissionTurn,
                      "\(label): real protocol reaches actual owned permission continuation")

                var drain: Task<Void, Never>?
                switch stop {
                case .composer: model.cancel()
                case .permissionCard:
                    let stopTurn = model.permissionTurnStopAction
                    // Native confirmationDialog dismissal clears the request
                    // binding before its button action can run.
                    model.answerPermission(.deny)
                    stopTurn?()
                case .actor: drain = Task { await session.cancelActiveTurn() }
                }
                let released = await waitUntil { model.pendingPermissionRequest == nil && model.responses.count == 1 }
                check(released && model.responses.first?.decision == .deny,
                      "\(label): cancellation denies the exact responder and clears its continuation")
                if !released { model.answerPermission(.deny) } // Bounded fixture-only containment.
                let drained = await waitUntil {
                    let running = await session.isRunning
                    return !running && model.consumerFinished
                        && backend.launchedProcesses.first?.wasTerminated == true
                }
                check(drained, "\(label): tested cancellation alone drains the producer without a second Stop")
                if !drained { await session.cancelActiveTurn() } // Only after recording failure.
                await drain?.value
                await consumer.value
                let stopped = await session.record
                let running = await session.isRunning
                check(model.consumerFinished && model.consumerError == nil && !running
                      && stopped.status == .idle && backend.launchedProcesses.count == 1
                      && backend.launchedProcesses.first?.wasTerminated == true,
                      "\(label): real runTurn drains, owned scripted process terminates and session is idle")
                let persisted = try store.loadSessions(matching: nil).first { $0.id == record.id }
                check(persisted?.status == .idle && model.permissionRequestToken == nil
                      && model.permissionContinuation == nil,
                      "\(label): durable idle state and no suspended permission remain")
                if stop == .actor {
                    check(completions(model.events).map(\.stopReason) == [.cancelled],
                          "\(label): live event consumer observes exactly one cancelled completion")
                }
                backend.enqueue(protocolScript(codex: codex, recovery: true))
                let recovery = try await session.send("offline recovery")
                var recovered: [AgentEvent] = []
                for try await event in recovery { recovered.append(event) }
                let recoveredRecord = await session.record
                let recoveredMessages = await session.messages
                let reply = codex ? recovered.compactMap { event -> Message? in
                    if case .messageCompleted(let message) = event, message.origin == .agent { return message }
                    return nil
                }.last?.plainText : completions(recovered).first?.finalText
                // Codex emits its answer as messageCompleted, not the summary's
                // optional finalText. Require the actual reply AND completion.
                check(reply == "OWN_RECOVERY_OK" && completions(recovered).count == 1
                      && completions(recovered).first?.stopReason == .completed
                      && recoveredMessages.last(where: { $0.origin == .agent })?.plainText == "OWN_RECOVERY_OK"
                      && recoveredRecord.status == .idle && backend.launchedRequests.count == 2,
                      "\(label): same actual AgentSession accepts and completes a subsequent turn")
            }
          }
        }

        if !failures.isEmpty {
            throw NSError(domain: "PermissionCancellationFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")])
        }
    }
}
