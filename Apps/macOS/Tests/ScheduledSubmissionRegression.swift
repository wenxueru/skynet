import Foundation
import SkynetCore

// The runner inserts actual queue persistence, scheduled dispatch, ordinary
// send/cancel and composer submission. Only UI presentation, account discovery
// and provider processes are substituted; all storage belongs to this fixture.
@MainActor
enum SessionTranscriptDiscovery {
    static func codexActivityReader(
        for record: SessionRecord, provider: AgentProviderDescriptor,
        notBefore: Date, startAtEnd: Bool
    ) async -> CodexSubagentActivityReader? { nil }
}

@MainActor
final class ScheduledModelHarness {
    // PRODUCTION_TYPES
    let store: JSONDiskStore?
    let backend: any ExecutionBackend
    var storageDirectoryURL: URL?
    var sessions: [SessionRecord]
    var providers = AgentProviderDescriptor.builtIns
    var selectedSessionID: SessionID?
    var selectedSession: SessionRecord? { sessions.first { $0.id == selectedSessionID } }
    var queuedPrompts: [QueuedPrompt] = []
    var pendingAttachments: [ImageAttachment] = []
    var scheduledQueueSessionIDs: Set<SessionID> = []
    var scheduledDispatch: Task<Void, Never>?
    var scheduledDispatchSessionID: SessionID?
    var scheduledSession: AgentSession?
    var steeringQueuedPromptID: UUID?
    var canSteerQueuedPrompt = false
    var isRunning = false
    var activeTurnSessionID: SessionID?
    var isSelectedSessionRunning: Bool { isRunning && selectedSessionID == activeTurnSessionID }
    // PRODUCTION_STOP_VISIBILITY
    var activeSession: AgentSession?
    var streamTask: Task<Void, Never>?
    var workingSince: Date?
    var scheduledErrorCount = 0
    var onScheduledError: (() -> Void)?
    var errorMessage: String? {
        didSet {
            if errorMessage?.hasPrefix("Scheduled message needs review:") == true {
                scheduledErrorCount += 1
                onScheduledError?()
            }
        }
    }
    var liveStatusText: String?
    var liveTools: [String] = []
    var pendingPermissionSessionID: SessionID?
    var permissionRequestToken: UUID?
    var permissionAnswers = 0
    var transcriptLoads: [SessionID] = []
    var appliedEvents: [AgentEvent] = []

    init(store: JSONDiskStore, root: URL, record: SessionRecord, backend: any ExecutionBackend) {
        self.store = store
        self.backend = backend
        storageDirectoryURL = root
        sessions = [record]
        selectedSessionID = record.id
    }
    func executionBackend(for record: SessionRecord) -> any ExecutionBackend { backend }
    func resetLiveState(for id: SessionID) {}
    func requestPermission(_ request: PermissionRequest, sessionID: SessionID, sessionTitle: String? = nil) async -> PermissionResponse {
        .init(requestID: request.id, decision: .deny)
    }
    func answerPermission(_ decision: PermissionResponse.Decision) { permissionAnswers += 1 }
    func replace(_ record: SessionRecord) {
        if let index = sessions.firstIndex(where: { $0.id == record.id }) { sessions[index] = record }
    }
    func loadTranscript(for id: SessionID) { transcriptLoads.append(id) }
    func apply(_ event: AgentEvent, sessionID: SessionID) { appliedEvents.append(event) }
    func seedDue(_ text: String) throws -> QueuedPrompt {
        let entry = QueuedPrompt(text: text, attachments: [], scheduledAt: Date().addingTimeInterval(-1))
        queuedPrompts.append(entry)
        try persistQueue(queuedPrompts, for: selectedSessionID!)
        return entry
    }
    func fireScheduled() { deliverMatureScheduledMessage() }
    func durableQueue(for id: SessionID) -> [QueuedPrompt] { queueEntries(for: id) }
    func rearmPendingQueue() throws { try persistQueue(queuedPrompts, for: selectedSessionID!) }
    func selectFixture(_ id: SessionID) { selectedSessionID = id; loadQueue(for: id) }
    // PRODUCTION_MEMBERS
}

@MainActor
final class ScheduledComposerHarness {
    enum Schedule {
        case date(Date)
        func fireDate(from now: Date) -> Date { switch self { case .date(let date): date } }
    }
    let model: ScheduledModelHarness
    var draft = ""
    var pendingSchedule: Schedule?
    init(model: ScheduledModelHarness) { self.model = model }
    func submitDraft() { submit() }
    // PRODUCTION_SUBMIT
}

@main
@MainActor
enum ScheduledSubmissionRegression {
    static func main() async {
        do { try await verify() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    private static func verify() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skynet-scheduled-submission-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JSONDiskStore(rootURL: root)
        var failures: [String] = []
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures.append(label) }
        }
        func record() -> SessionRecord {
            var record = SessionRecord(projectID: ProjectID(), providerID: .codex)
            record.workingDirectory = root.path
            record.codexApprovalMode = .automatic
            return record
        }

        let backend = ScriptedExecutionBackend(scripts: [
            .init(onStdin: { _, _ in }),
            .init(stdoutLines: [#"{"type":"turn.completed"}"#]),
        ])
        let model = ScheduledModelHarness(store: store, root: root, record: record(), backend: backend)
        let composer = ScheduledComposerHarness(model: model)
        let due = try model.seedDue("owned scheduled lead")
        model.fireScheduled()
        let scheduledTask = model.scheduledDispatch
        try await eventually { backend.launchedProcesses.count == 1 }
        check(model.scheduledDispatchSessionID == model.selectedSessionID
              && model.queuedPrompts.first?.dispatchStartedAt != nil,
              "real scheduled coordinator is sending a marked durable entry")
        composer.draft = "owned follow-up 中文"
        composer.submitDraft()
        check(composer.draft.isEmpty && model.queuedPrompts.contains { $0.text == "owned follow-up 中文" }
              && model.errorMessage == nil,
              "actual composer submission queues instead of silently losing text during scheduled send")
        // Seed the follow-up explicitly only on a failing baseline, so its
        // independent completion/dispatch assertion isn't masked by draft loss.
        if !model.queuedPrompts.contains(where: { $0.text == "owned follow-up 中文" }) {
            _ = model.enqueueDraft("owned follow-up 中文")
            model.errorMessage = nil
        }
        let followUpID = model.queuedPrompts.first { $0.text == "owned follow-up 中文" }?.id
        check(model.durableQueue(for: model.selectedSessionID!).map(\.id) == [due.id, followUpID!]
              && backend.launchedRequests.count == 1,
              "pending follow-up is durable and cannot launch concurrently in the scheduled session")
        backend.launchedProcesses[0].emitStdout(#"{"type":"turn.completed"}"#)
        backend.launchedProcesses[0].finishStdout()
        await scheduledTask?.value
        // Allow the completion-triggered ordinary task to finish; no resend.
        for _ in 0..<100 where backend.launchedRequests.count < 2 { await Task.yield() }
        await model.streamTask?.value
        check(backend.launchedRequests.count == 2,
              "successful scheduled completion automatically dispatches the waiting ordinary follow-up")
        check(model.queuedPrompts.isEmpty && model.durableQueue(for: model.selectedSessionID!).isEmpty,
              "successful scheduled and ordinary deliveries remove only their acknowledged entries")
        check(model.scheduledDispatchSessionID == nil && !model.isRunning,
              "both coordinators settle without a phantom active turn")

        let failureBackend = ScriptedExecutionBackend(scripts: [.init(exitCode: 1, onStdin: { _, _ in })])
        let failed = ScheduledModelHarness(store: store, root: root, record: record(), backend: failureBackend)
        let failedComposer = ScheduledComposerHarness(model: failed)
        let failedEntry = try failed.seedDue("owned failed schedule")
        failed.fireScheduled()
        let failedTask = failed.scheduledDispatch
        try await eventually { failureBackend.launchedProcesses.count == 1 }
        failedComposer.draft = "owned retained follow-up"
        failedComposer.submitDraft()
        check(failed.queuedPrompts.contains { $0.text == "owned retained follow-up" },
              "scheduled failure fixture also preserves composer follow-up before terminal failure")
        if !failed.queuedPrompts.contains(where: { $0.text == "owned retained follow-up" }) {
            _ = failed.enqueueDraft("owned retained follow-up")
        }
        failureBackend.launchedProcesses[0].emitStdout(#"{"type":"turn.failed","error":{"message":"owned fixture failure"}}"#)
        failureBackend.launchedProcesses[0].finishStdout()
        await failedTask?.value
        check(failureBackend.launchedRequests.count == 1 && failed.queuedPrompts.count == 2
              && failed.queuedPrompts.first?.id == failedEntry.id
              && failed.queuedPrompts.first?.dispatchStartedAt != nil,
              "failed scheduled delivery retains uncertain entry and backlog without automatic retry/advance")
        check(failed.errorMessage?.contains("needs review") == true
              && failed.scheduledDispatchSessionID == nil,
              "scheduled failure returns to reviewable non-running state")

        let stoppedBackend = ScriptedExecutionBackend(scripts: [.init(onStdin: { _, _ in })])
        let stopped = ScheduledModelHarness(store: store, root: root, record: record(), backend: stoppedBackend)
        let stoppedEntry = try stopped.seedDue("owned schedule to stop")
        stopped.fireScheduled()
        let stoppedTask = stopped.scheduledDispatch
        try await eventually { stoppedBackend.launchedProcesses.count == 1 }
        check(stopped.canStopSelectedSession && !stopped.isRunning,
              "actual Stop visibility includes the independently running scheduled session")
        _ = stopped.enqueueDraft("owned backlog must remain after Stop")
        stopped.pendingPermissionSessionID = SessionID()
        stopped.cancel()
        for _ in 0..<50 { try await Task.sleep(for: .milliseconds(10)) }
        check(stoppedBackend.launchedProcesses[0].wasTerminated,
              "Stop terminates the selected scheduled provider, not only ordinary sends")
        check(stopped.permissionAnswers == 0,
              "scheduled Stop cannot answer another fixture session's pending permission")
        // Only contain the baseline fixture's own process so the assertion
        // finishes; this must never manufacture a production cancellation pass.
        if !stoppedBackend.launchedProcesses[0].wasTerminated {
            stoppedBackend.launchedProcesses[0].finishStdout()
        }
        await stoppedTask?.value
        check(stopped.scheduledDispatchSessionID == nil && stoppedBackend.launchedRequests.count == 1
              && stopped.durableQueue(for: stopped.selectedSessionID!).count == 2
              && stopped.durableQueue(for: stopped.selectedSessionID!).first?.id == stoppedEntry.id,
              "stopped scheduled delivery retains review marker/backlog without advancing")
        check(!stopped.canStopSelectedSession && stopped.scheduledSession == nil,
              "completed scheduled cancellation clears provider ownership and Stop visibility")

        let heldBase = ScriptedExecutionBackend(scripts: [.init(onStdin: { _, _ in })])
        let heldBackend = DelayedTerminationBackend(base: heldBase)
        let held = ScheduledModelHarness(store: store, root: root, record: record(), backend: heldBackend)
        _ = try held.seedDue("owned held-termination schedule")
        held.fireScheduled()
        let heldTask = held.scheduledDispatch
        try await eventually { heldBase.launchedProcesses.count == 1 }
        _ = held.enqueueDraft("owned held backlog")
        held.pendingPermissionSessionID = held.selectedSessionID
        held.cancel()
        check(held.permissionAnswers == 1,
              "scheduled Stop denies only its own pending permission")
        for _ in 0..<100 {
            if await heldBackend.gate.wasRequested { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(held.scheduledDispatchSessionID == held.selectedSessionID
              && held.scheduledSession != nil && held.canStopSelectedSession
              && !heldBase.launchedProcesses[0].wasTerminated && heldBase.launchedRequests.count == 1,
              "scheduled Stop retains ownership and blocks backlog until held termination finishes")
        await heldBackend.gate.release()
        await heldTask?.value
        check(heldBase.launchedProcesses[0].wasTerminated && held.scheduledSession == nil
              && held.scheduledDispatchSessionID == nil && heldBase.launchedRequests.count == 1
              && held.durableQueue(for: held.selectedSessionID!).count == 2,
              "scheduled termination finishes before cleanup without starting its retained backlog")

        let earlyBackend = ScriptedExecutionBackend(scripts: [.init(onStdin: { _, _ in })])
        let early = ScheduledModelHarness(store: store, root: root, record: record(), backend: earlyBackend)
        let earlyEntry = try early.seedDue("owned pre-launch schedule to stop")
        early.fireScheduled()
        let earlyTask = early.scheduledDispatch
        early.cancel()
        for _ in 0..<50 { try await Task.sleep(for: .milliseconds(10)) }
        check(earlyBackend.launchedRequests.isEmpty,
              "Stop before scheduled preparation prevents provider launch")
        earlyBackend.launchedProcesses.forEach { $0.finishStdout() }
        await earlyTask?.value
        check(early.durableQueue(for: early.selectedSessionID!).first?.id == earlyEntry.id
              && early.durableQueue(for: early.selectedSessionID!).first?.dispatchStartedAt == nil,
              "pre-launch scheduled Stop retains an unmarked unsent entry")

        let concurrentBackend = ScriptedExecutionBackend(scripts: [
            .init(onStdin: { _, _ in }), .init(onStdin: { _, _ in }),
        ])
        let concurrent = ScheduledModelHarness(store: store, root: root, record: record(), backend: concurrentBackend)
        let scheduledID = concurrent.selectedSessionID!
        _ = try concurrent.seedDue("owned scheduled cancellation target")
        concurrent.fireScheduled()
        let concurrentSchedule = concurrent.scheduledDispatch
        try await eventually { concurrentBackend.launchedProcesses.count == 1 }
        let ordinarySibling = record()
        concurrent.sessions.append(ordinarySibling)
        concurrent.selectFixture(ordinarySibling.id)
        concurrent.send("owned ordinary sibling control")
        let concurrentOrdinary = concurrent.streamTask
        try await eventually { concurrentBackend.launchedProcesses.count == 2 }
        concurrent.selectFixture(scheduledID)
        concurrent.pendingPermissionSessionID = ordinarySibling.id
        concurrent.cancel()
        await concurrentSchedule?.value
        check(concurrentBackend.launchedProcesses[0].wasTerminated
              && !concurrentBackend.launchedProcesses[1].wasTerminated
              && concurrent.isRunning && concurrent.permissionAnswers == 0,
              "selected scheduled Stop leaves the concurrent ordinary fixture actor and permission untouched")
        concurrent.selectFixture(ordinarySibling.id)
        concurrent.cancel()
        await concurrentOrdinary?.value
        check(concurrentBackend.launchedProcesses[1].wasTerminated && !concurrent.isRunning
              && concurrent.permissionAnswers == 1,
              "ordinary Stop still terminates its exact sibling actor and answers its own permission")
        check(concurrent.durableQueue(for: scheduledID).first?.dispatchStartedAt != nil,
              "independent ordinary cancellation cannot clear the stopped scheduled review entry")

        let otherBackend = ScriptedExecutionBackend(scripts: [.init(onStdin: { _, _ in })])
        let other = ScheduledModelHarness(store: store, root: root, record: record(), backend: otherBackend)
        let originalID = other.selectedSessionID!
        _ = try other.seedDue("owned unselected schedule")
        other.fireScheduled()
        let otherTask = other.scheduledDispatch
        try await eventually { otherBackend.launchedProcesses.count == 1 }
        let sibling = record()
        other.sessions.append(sibling)
        other.selectedSessionID = sibling.id
        other.queuedPrompts = []
        check(!other.canStopSelectedSession,
              "another selection cannot expose Stop for an unselected scheduled provider")
        other.cancel()
        for _ in 0..<20 { await Task.yield() }
        check(!otherBackend.launchedProcesses[0].wasTerminated,
              "unselected scheduled provider is not cancelled by another selection")
        otherBackend.launchedProcesses[0].emitStdout(#"{"type":"turn.completed"}"#)
        otherBackend.launchedProcesses[0].finishStdout()
        await otherTask?.value
        check(other.selectedSessionID == sibling.id && other.queuedPrompts.isEmpty
              && other.transcriptLoads.isEmpty && other.durableQueue(for: originalID).isEmpty,
              "unselected schedule completion never reloads or switches another selection")

        let blocker = root.appendingPathComponent("own-blocker")
        try Data([0]).write(to: blocker)
        let blocked = ScheduledModelHarness(store: store, root: blocker, record: record(),
                                            backend: ScriptedExecutionBackend())
        blocked.scheduledDispatchSessionID = blocked.selectedSessionID
        let blockedComposer = ScheduledComposerHarness(model: blocked)
        blockedComposer.draft = "owned write failure must remain"
        blockedComposer.submitDraft()
        check(blockedComposer.draft == "owned write failure must remain" && blocked.queuedPrompts.isEmpty,
              "failed persistence leaves scheduled-session composer text intact")

        let ordinaryBackend = ScriptedExecutionBackend(scripts: [.init(stdoutLines: [#"{"type":"turn.completed"}"#])])
        let idle = ScheduledModelHarness(store: store, root: root, record: record(), backend: ordinaryBackend)
        let idleComposer = ScheduledComposerHarness(model: idle)
        idleComposer.draft = "owned idle direct send"
        idleComposer.submitDraft()
        await idle.streamTask?.value
        check(idleComposer.draft.isEmpty && ordinaryBackend.launchedRequests.count == 1
              && idle.queuedPrompts.isEmpty && !idle.isRunning,
              "idle ordinary submission still sends directly and settles")
        idle.isRunning = true
        idleComposer.draft = "owned ordinary busy queue"
        idleComposer.submitDraft()
        check(idleComposer.draft.isEmpty && idle.queuedPrompts.first?.text == "owned ordinary busy queue"
              && ordinaryBackend.launchedRequests.count == 1,
              "ordinary busy submission retains existing queue behavior")
        idle.isRunning = false
        idle.scheduledDispatchSessionID = SessionID()
        check(!idle.shouldQueueComposerSubmission,
              "another scheduled identity alone cannot mark selected composer busy")
        idle.selectedSessionID = nil
        idle.scheduledDispatchSessionID = nil
        check(!idle.shouldQueueComposerSubmission, "two absent identities are not a scheduled send")

        let imageModel = ScheduledModelHarness(store: store, root: root, record: record(),
                                              backend: ScriptedExecutionBackend())
        imageModel.scheduledDispatchSessionID = imageModel.selectedSessionID
        let imageComposer = ScheduledComposerHarness(model: imageModel)
        let image = ImageAttachment(data: Data([1, 2, 3]), mediaType: "image/png")
        imageModel.pendingAttachments = [image]
        imageComposer.submitDraft()
        check(imageModel.queuedPrompts.count == 1 && imageModel.pendingAttachments.isEmpty,
              "image-only draft is queued during scheduled send instead of rejected")
        if case .blob(let reference) = imageModel.queuedPrompts.first?.attachments.first?.payload {
            check(try store.loadBlob(reference) == Data([1, 2, 3]),
                  "queued draft image bytes are durably retained by the real blob store")
        } else { check(false, "queued draft image bytes are durably retained by the real blob store") }

        let deniedRoot = root.appendingPathComponent("own-denied-queue")
        let deniedStore = try JSONDiskStore(rootURL: deniedRoot)
        let deniedBackend = ScriptedExecutionBackend(scripts: [.init(stdoutLines: [#"{"type":"turn.completed"}"#])])
        let denied = ScheduledModelHarness(store: deniedStore, root: deniedRoot, record: record(), backend: deniedBackend)
        let deniedEntry = try denied.seedDue("owned queue write denial")
        let deniedDirectory = deniedRoot.appendingPathComponent("message-queues")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: deniedDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deniedDirectory.path) }
        // Contain the old immediate retry loop after three observed real write
        // errors so a failing baseline remains bounded and leaves no live task.
        denied.onScheduledError = { [weak denied] in
            guard let denied, denied.scheduledErrorCount >= 3 else { return }
            denied.scheduledQueueSessionIDs.remove(denied.selectedSessionID!)
        }
        denied.fireScheduled()
        await denied.scheduledDispatch?.value
        try await eventually { denied.scheduledDispatch == nil }
        print("OBSERVE: own persistent queue failure errors=\(denied.scheduledErrorCount), provider launches=\(deniedBackend.launchedRequests.count)")
        check(denied.scheduledErrorCount == 1 && deniedBackend.launchedRequests.isEmpty,
              "pre-launch queue write failure yields one review error instead of an immediate retry loop")
        check(denied.durableQueue(for: denied.selectedSessionID!).map(\.id) == [deniedEntry.id]
              && denied.queuedPrompts.first?.dispatchStartedAt == nil,
              "failed dispatch-marker write preserves the original unsent durable entry")
        denied.fireScheduled() // Models the ordinary timer's next tick.
        check(denied.scheduledDispatch == nil && denied.scheduledErrorCount == 1,
              "later scheduler ticks cannot silently retry the session awaiting queue review")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deniedDirectory.path)
        denied.onScheduledError = nil
        try denied.rearmPendingQueue() // Explicit queue persistence after review.
        denied.fireScheduled()
        await denied.scheduledDispatch?.value
        check(deniedBackend.launchedRequests.count == 1
              && denied.durableQueue(for: denied.selectedSessionID!).isEmpty,
              "explicit queue re-persistence after write recovery re-enables one successful delivery")

        let transientRoot = root.appendingPathComponent("own-transient-queue")
        let transientStore = try JSONDiskStore(rootURL: transientRoot)
        let transientBackend = ScriptedExecutionBackend(scripts: [
            .init(stdoutLines: [#"{"type":"turn.completed"}"#]),
            .init(stdoutLines: [#"{"type":"turn.completed"}"#]),
        ])
        let transient = ScheduledModelHarness(store: transientStore, root: transientRoot,
                                              record: record(), backend: transientBackend)
        let reviewedID = transient.selectedSessionID!
        let reviewedEntry = try transient.seedDue("owned transient failure stays for review")
        // Distinct fixture identity only, never an account/project session.
        let healthy = record()
        transient.sessions.append(healthy)
        transient.selectFixture(healthy.id)
        _ = try transient.seedDue("owned healthy scheduled sibling")
        transient.selectFixture(reviewedID)
        let transientDirectory = transientRoot.appendingPathComponent("message-queues")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: transientDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transientDirectory.path) }
        transient.onScheduledError = {
            // Recover only this fixture directory after its first actual
            // filesystem failure; don't alter account/system permissions.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transientDirectory.path)
        }
        transient.fireScheduled()
        await transient.scheduledDispatch?.value
        try await eventually { transient.scheduledDispatch == nil }
        print("OBSERVE: own transient queue failure errors=\(transient.scheduledErrorCount), provider launches=\(transientBackend.launchedRequests.count), review entries=\(transient.durableQueue(for: reviewedID).count), healthy entries=\(transient.durableQueue(for: healthy.id).count), selected reloads=\(transient.transcriptLoads.count)")
        check(transientBackend.launchedRequests.count == 1
              && transient.durableQueue(for: reviewedID).map(\.id) == [reviewedEntry.id],
              "transient write recovery cannot automatically resend a session already requiring review")
        check(transient.durableQueue(for: healthy.id).isEmpty && transient.selectedSessionID == reviewedID
              && transient.transcriptLoads.isEmpty,
              "a paused failed schedule cannot starve another own scheduled identity or switch selection")
        if !failures.isEmpty {
            throw NSError(domain: "ScheduledSubmissionFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")])
        }
    }

    private static func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "ScheduledSubmissionFixture", code: 2) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
// PRODUCTION_RESPONDER
// TERMINATION_HELPERS
