// Runner inserts actual AppModel.send/cancel and QueuedPrompt. No AppModel.init,
// account storage, real provider, operating-system process, or app UI is used.
// --local-process additionally owns real sleep children, never a provider CLI.
import Darwin
// Only source resolution is stubbed: the optional reader below reads our own
// fixture. Actual send/monitor/cancel methods are extracted by the runner.
@MainActor
enum SessionTranscriptDiscovery {
    static var fixtureReader: CodexSubagentActivityReader?
    static func codexActivityReader(
        for record: SessionRecord, provider: AgentProviderDescriptor,
        notBefore: Date, startAtEnd: Bool
    ) async -> CodexSubagentActivityReader? { fixtureReader }
}
@MainActor
final class AppModel {
    let store: JSONDiskStore?
    let backend: ScriptedExecutionBackend
    var overrideBackend: (any ExecutionBackend)?
    var selectedSession: SessionRecord?
    var selectedSessionID: SessionID?
    var providers = AgentProviderDescriptor.builtIns
    var sessions: [SessionRecord] = []
    var pendingAttachments: [ImageAttachment] = []
    var isRunning = false
    var activeTurnSessionID: SessionID?
    var workingSince: Date?
    var errorMessage: String?
    var activeSession: AgentSession?
    var streamTask: Task<Void, Never>?
    var liveStatusText: String?
    var liveTools: [String] = []
    var steeringQueuedPromptID: UUID?
    var scheduledDispatchSessionID: SessionID?
    var scheduledDispatch: Task<Void, Never>?
    var scheduledSession: AgentSession?
    var pendingPermissionSessionID: SessionID?
    var permissionRequestToken: UUID?
    var fixtureQueue: [QueuedPrompt] = []
    var dispatched: [UUID] = []
    var nextQueueCount = 0
    var cancelledEvents = 0
    var permissionAnswers = 0
    var steerOnCompletion: UUID?
    var stopOnCompletion = false
    var onDispatch: ((QueuedPrompt) -> Void)?
    var activityReports: [SubagentStatusReport] = []

    init(store: JSONDiskStore, record: SessionRecord, backend: ScriptedExecutionBackend) {
        self.store = store
        self.selectedSession = record
        self.selectedSessionID = record.id
        self.backend = backend
    }
    func executionBackend(for record: SessionRecord) -> any ExecutionBackend { overrideBackend ?? backend }
    func resetLiveState(for id: SessionID) {}
    func requestPermission(_ request: PermissionRequest, sessionID: SessionID) async -> PermissionResponse {
        .init(requestID: request.id, decision: .deny)
    }
    func answerPermission(_ decision: PermissionResponse.Decision) { permissionAnswers += 1 }
    func removeQueuedPrompt(_ id: UUID, for sessionID: SessionID) {
        fixtureQueue.removeAll { $0.id == id }
    }
    func queueEntries(for id: SessionID) -> [QueuedPrompt] { fixtureQueue }
    func sendQueuedPrompt(_ entry: QueuedPrompt, for sessionID: SessionID) {
        dispatched.append(entry.id)
        onDispatch?(entry)
    }
    func sendNextQueued(for id: SessionID) { nextQueueCount += 1 }
    func replace(_ record: SessionRecord) { selectedSession = record }
    func apply(_ event: AgentEvent, sessionID: SessionID) {
        if case .subagentStatusReported(let report) = event { activityReports.append(report) }
        if case .turnCompleted(let summary) = event, summary.stopReason == .completed {
            if let steerOnCompletion {
                steeringQueuedPromptID = steerOnCompletion
                cancel()
            } else if stopOnCompletion {
                cancel()
            }
        }
        if case .turnCompleted(let summary) = event, summary.stopReason == .cancelled {
            cancelledEvents += 1
        }
    }
    // PRODUCTION_MEMBERS
}

@main
@MainActor
enum TurnCancellationRegression {
    static func main() async {
        do { try await verify() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    private static func verify() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skynet-cancel-fixture-\(UUID().uuidString)")
        let store = try JSONDiskStore(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = SessionRecord(projectID: ProjectID(), providerID: .codex)
        var failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            print("\(value ? "PASS" : "FAIL"): \(label)")
            if !value { failures.append(label) }
        }
        let backend = ScriptedExecutionBackend(scripts: [.init(stdoutLines: [#"{"type":"turn.completed"}"#])])
        let draftImage = ImageAttachment(data: Data([8]), mediaType: "image/png")
        let queueImage = ImageAttachment(data: Data([9]), mediaType: "image/png")
        for rejection in ["provider", "selection", "running", "scheduled", "identity"] {
            let rejectedRecord = SessionRecord(projectID: ProjectID(), providerID: .codex)
            let rejectedBackend = ScriptedExecutionBackend()
            let rejected = AppModel(store: store, record: rejectedRecord, backend: rejectedBackend)
            let queued = AppModel.QueuedPrompt(text: "owned rejected dispatch", attachments: [queueImage])
            rejected.fixtureQueue = [queued]
            rejected.pendingAttachments = [draftImage]
            switch rejection {
            case "provider": rejected.providers = []
            case "selection": rejected.selectedSession = nil
            case "running": rejected.isRunning = true
            case "scheduled": rejected.scheduledDispatchSessionID = rejectedRecord.id
            default: rejected.selectedSessionID = SessionID() // Own synthetic identity only.
            }
            // Actual queue handoff + actual send guards, not the dispatch stub.
            rejected.productionSendQueuedPrompt(queued, for: rejectedRecord.id)
            check(rejected.pendingAttachments.map(\.id) == [draftImage.id],
                  "\(rejection): rejected actual queued send preserves only the unsent composer image")
            check(rejectedBackend.launchedRequests.isEmpty && rejected.streamTask == nil
                  && rejected.fixtureQueue.map(\.id) == [queued.id],
                  "\(rejection): rejected dispatch neither launches nor consumes its queued entry")
        }

        let acceptedRecord = SessionRecord(projectID: ProjectID(), providerID: .codex)
        let accepted = AppModel(store: store, record: acceptedRecord, backend: ScriptedExecutionBackend())
        let acceptedEntry = AppModel.QueuedPrompt(text: "owned accepted dispatch", attachments: [queueImage])
        accepted.fixtureQueue = [acceptedEntry]
        accepted.pendingAttachments = [draftImage]
        accepted.productionSendQueuedPrompt(acceptedEntry, for: acceptedRecord.id)
        let acceptedTask = accepted.streamTask
        check(accepted.isRunning && acceptedTask != nil && accepted.pendingAttachments.map(\.id) == [draftImage.id],
              "accepted queue handoff starts preparation while preserving the composer image")
        accepted.cancel()
        await acceptedTask?.value
        check(accepted.pendingAttachments.map(\.id) == [draftImage.id]
              && accepted.fixtureQueue.map(\.id) == [acceptedEntry.id],
              "queued preparation cancellation preserves independent composer and pending entry")

        let deliveredRecord = SessionRecord(projectID: ProjectID(), providerID: .claudeCode)
        let deliveredBackend = ScriptedExecutionBackend(scripts: [.init(stdoutLines: [
            #"{"type":"assistant","message":{"id":"owned-queue-answer","role":"assistant","content":[{"type":"text","text":"OWN_QUEUED_IMAGE_OK"}]}}"#,
            #"{"type":"result","subtype":"success","result":"OWN_QUEUED_IMAGE_OK","session_id":"owned-queue-image"}"#,
        ])])
        let delivered = AppModel(store: store, record: deliveredRecord, backend: deliveredBackend)
        let deliveredEntry = AppModel.QueuedPrompt(text: "owned successful queue image", attachments: [queueImage])
        delivered.fixtureQueue = [deliveredEntry]
        delivered.pendingAttachments = [draftImage]
        delivered.productionSendQueuedPrompt(deliveredEntry, for: deliveredRecord.id)
        await delivered.streamTask?.value
        let deliveredUsers = try store.loadMessages(for: deliveredRecord.id).filter { $0.origin == .user }
        let deliveredImageIDs = deliveredUsers.flatMap(\.content).compactMap { block -> UUID? in
            if case .image(let image) = block { return image.id }
            return nil
        }
        check(deliveredBackend.launchedRequests.count == 1 && deliveredUsers.count == 1
              && deliveredImageIDs == [queueImage.id] && delivered.fixtureQueue.isEmpty,
              "successful actual queued send persists only its own image and consumes exactly one entry")
        check(!delivered.isRunning && delivered.pendingAttachments.map(\.id) == [draftImage.id],
              "successful queued completion leaves the independent composer image intact")

        let model = AppModel(store: store, record: record, backend: backend)
        let attachment = ImageAttachment(data: Data([1, 2, 3]), mediaType: "image/png")
        model.pendingAttachments = [attachment]
        model.send("owned early cancellation fixture")
        let preparing = model.streamTask
        model.liveTools = ["owned stale row"]
        model.cancel() // Before the MainActor send task can begin preparation.
        await preparing?.value
        check(backend.launchedRequests.isEmpty, "Stop before preparation prevents backend launch")
        check(try store.loadMessages(for: record.id).isEmpty,
              "Stop before preparation does not persist an unstarted prompt")
        check(!model.isRunning && model.activeSession == nil,
              "early Stop settles the actual UI coordinator")
        check(model.liveTools.isEmpty, "cancelled consumer clears its stale current activity")
        check(model.pendingAttachments.map(\.id) == [attachment.id],
              "unstarted direct-send attachments return to their composer")

        let switchingRecord = SessionRecord(projectID: ProjectID(), providerID: .codex)
        let switching = AppModel(store: store, record: switchingRecord,
                                 backend: ScriptedExecutionBackend())
        let otherAttachment = ImageAttachment(data: Data([4]), mediaType: "image/png")
        switching.pendingAttachments = [attachment]
        switching.send("owned cancellation selection fixture")
        let switchingTask = switching.streamTask
        switching.cancel()
        switching.selectedSessionID = SessionID() // Synthetic identity only; no account session.
        switching.pendingAttachments = [otherAttachment]
        await switchingTask?.value
        check(switching.pendingAttachments.map(\.id) == [otherAttachment.id],
              "cancelled preparation cannot inject attachments into another selection")

        let steeringRecord = SessionRecord(projectID: ProjectID(), providerID: .codex)
        let steeringBackend = ScriptedExecutionBackend()
        let steering = AppModel(store: store, record: steeringRecord, backend: steeringBackend)
        let entry = AppModel.QueuedPrompt(text: "owned next queued fixture", attachments: [])
        steering.fixtureQueue = [entry]
        steering.send("owned steer-before-launch fixture")
        let steeringTask = steering.streamTask
        steering.steeringQueuedPromptID = entry.id
        steering.cancel()
        await steeringTask?.value
        check(steeringBackend.launchedRequests.isEmpty && steering.dispatched == [entry.id],
              "early Steer skips old launch and dispatches prioritized queue entry once")

        let finishing = AppModel(store: store,
                                 record: SessionRecord(projectID: ProjectID(), providerID: .codex),
                                 backend: ScriptedExecutionBackend())
        finishing.fixtureQueue = [entry]
        finishing.steerOnCompletion = entry.id
        finishing.send("owned completion-edge steer fixture")
        await finishing.streamTask?.value
        check(finishing.dispatched == [entry.id] && finishing.nextQueueCount == 0,
              "Steer at completion still dispatches exactly the prioritized entry")
        let stopping = AppModel(store: store,
                                record: SessionRecord(projectID: ProjectID(), providerID: .codex),
                                backend: ScriptedExecutionBackend())
        stopping.stopOnCompletion = true
        stopping.send("owned completion-edge stop fixture")
        await stopping.streamTask?.value
        check(stopping.nextQueueCount == 0,
              "Stop at completion cannot automatically start another queued turn")

        let completing = AppModel(store: store,
                                  record: SessionRecord(projectID: ProjectID(), providerID: .codex),
                                  backend: ScriptedExecutionBackend())
        completing.send("owned ordinary completion fixture")
        await completing.streamTask?.value
        check(completing.nextQueueCount == 1,
              "ordinary completion retains automatic queue dispatch")

        for exitCode: Int32 in [0, 1] {
            let errorRecord = SessionRecord(projectID: ProjectID(), providerID: .claudeCode)
            let errorBackend = ScriptedExecutionBackend(scripts: [
                .init(exitCode: exitCode, stdoutLines: [
                    #"{"type":"result","subtype":"success","is_error":true,"result":"API Error: own fixture unavailable"}"#,
                ]),
                .init(stdoutLines: [#"{"type":"result","subtype":"success","result":"own recovery"}"#]),
            ])
            let failed = AppModel(store: store, record: errorRecord, backend: errorBackend)
            failed.fixtureQueue = [entry]
            failed.send("own Claude error routing fixture")
            await failed.streamTask?.value
            check(failed.nextQueueCount == 0 && failed.fixtureQueue.map(\.id) == [entry.id]
                  && failed.selectedSession?.status == .failed && !failed.isRunning,
                  "Claude is_error exit \(exitCode) retains queue and failed state without auto dispatch")
            failed.send("own explicit recovery fixture")
            await failed.streamTask?.value
            check(failed.nextQueueCount == 1 && failed.selectedSession?.status == .idle
                  && errorBackend.launchedRequests.count == 2,
                  "Claude is_error exit \(exitCode) permits one explicit successful recovery")
        }

        let rollout = root.appendingPathComponent("own-activity.jsonl")
        try Data().write(to: rollout)
        let activityReader = try CodexSubagentActivityReader(
            url: rollout, parentThreadID: "own-parent", notBefore: Date(timeIntervalSince1970: 100)
        )
        SessionTranscriptDiscovery.fixtureReader = activityReader
        let activityBackend = ScriptedExecutionBackend(scripts: [.init(onStdin: { _, _ in })])
        let activity = AppModel(store: store, record: record, backend: activityBackend)
        activity.send("owned parent activity fixture")
        let activityTurn = activity.streamTask
        try await eventually { !activityBackend.launchedProcesses.isEmpty }
        let writer = try FileHandle(forWritingTo: rollout)
        defer { try? writer.close() }
        let begin = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"own-turn","started_at":100}}"# + "\n"
        func lifecycle(_ kind: String) -> String {
            #"{"type":"event_msg","payload":{"type":"item_completed","thread_id":"own-parent","turn_id":"own-turn","item":{"type":"SubAgentActivity","kind":"\#(kind)","agent_thread_id":"own-child","agent_path":"/root/own-child"}}}"# + "\n"
        }
        try writer.write(contentsOf: Data((begin + lifecycle("started")).utf8))
        try await eventually { activity.activityReports.count == 1 }
        check(activity.activityReports[0].status == .running,
              "actual send monitor receives the own parent rollout's running child")
        try writer.write(contentsOf: Data(lifecycle("completed").utf8))
        activityBackend.launchedProcesses[0].finishStdout()
        await activityTurn?.value
        check(activity.activityReports.map(\.status) == [.running, .completed]
              && activity.nextQueueCount == 1,
              "final drain observes completion before ordinary queue dispatch")
        try writer.write(contentsOf: Data(lifecycle("failed").utf8))
        try await Task.sleep(for: .milliseconds(300))
        check(activity.activityReports.count == 2,
              "finished send owns no lingering activity listener")
        SessionTranscriptDiscovery.fixtureReader = try CodexSubagentActivityReader(
            url: rollout, parentThreadID: "own-parent", notBefore: Date(timeIntervalSince1970: 100)
        )
        let stoppedActivityBackend = ScriptedExecutionBackend(scripts: [.init(onStdin: { _, _ in })])
        let stoppedActivity = AppModel(store: store, record: record, backend: stoppedActivityBackend)
        stoppedActivity.send("owned activity stop fixture")
        let stoppedActivityTurn = stoppedActivity.streamTask
        try await eventually { !stoppedActivityBackend.launchedProcesses.isEmpty }
        try writer.write(contentsOf: Data((begin + lifecycle("started")).utf8))
        try await eventually { stoppedActivity.activityReports.count == 1 }
        stoppedActivity.cancel()
        await stoppedActivityTurn?.value
        try writer.write(contentsOf: Data(lifecycle("completed").utf8))
        try await Task.sleep(for: .milliseconds(300))
        check(stoppedActivity.activityReports.count == 1 && stoppedActivity.nextQueueCount == 0,
              "Stop awaits listener cleanup and cannot import late child completion")
        SessionTranscriptDiscovery.fixtureReader = nil

        let delayedBase = ScriptedExecutionBackend(scripts: [.init(onStdin: { _, _ in })])
        let delayedBackend = DelayedTerminationBackend(base: delayedBase)
        let draining = AppModel(store: store,
                                record: SessionRecord(projectID: ProjectID(), providerID: .codex),
                                backend: delayedBase)
        draining.overrideBackend = delayedBackend
        draining.fixtureQueue = [entry]
        draining.send("owned delayed termination fixture")
        let drainingTask = draining.streamTask
        try await eventually { !delayedBase.launchedProcesses.isEmpty }
        draining.steeringQueuedPromptID = entry.id
        draining.cancel()
        try await eventuallyAsync { await delayedBackend.gate.wasRequested }
        try await Task.sleep(for: .milliseconds(100))
        check(draining.dispatched.isEmpty,
              "Steer waits for original process termination before starting its next entry")
        await delayedBackend.gate.release()
        await drainingTask?.value
        try await eventually { delayedBase.launchedProcesses[0].wasTerminated }
        check(draining.dispatched == [entry.id] && !draining.isRunning,
              "queued dispatch proceeds once after owned termination is released")

        // A running core session uses an in-memory scripted process only.
        let liveBackend = ScriptedExecutionBackend(scripts: [.init(onStdin: { _, _ in })])
        let liveRecord = SessionRecord(projectID: ProjectID(), providerID: .codex)
        let provider = AgentProviderDescriptor.builtIns.first { $0.id == .codex }!
        let live = try AgentSession(record: liveRecord,
                                    configuration: .init(provider: provider, backend: liveBackend))
        let events = try await live.send("owned live core fixture")
        let consumer = Task { for try await _ in events {} }
        try await eventually { !liveBackend.launchedProcesses.isEmpty }
        let old = try AgentSession(record: record,
                                   configuration: .init(provider: provider, backend: backend))
        model.activeSession = old
        model.cancel()
        model.activeSession = live // Simulate coordinator moving to the next turn before callback runs.
        try await Task.sleep(for: .milliseconds(100))
        check(!liveBackend.launchedProcesses[0].wasTerminated,
              "Stop callback captures its original actor, not a later turn")
        await live.cancelActiveTurn()
        _ = try await consumer.value
        let remainsRunning = await live.isRunning
        check(liveBackend.launchedProcesses[0].wasTerminated && !remainsRunning,
              "owned scripted live turn cleans up through its original handle")

        if CommandLine.arguments.contains("--local-process") {
            try await verifyLocalTermination(store: store, check: check)
        }

        if !failures.isEmpty { throw FixtureFailure.mismatch(failures) }
    }

    private static func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureFailure.timeout
    }
    private static func eventuallyAsync(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureFailure.timeout
    }
    private enum FixtureFailure: Error { case mismatch([String]), timeout }

    private static func verifyLocalTermination(
        store: JSONDiskStore, check: (Bool, String) -> Void
    ) async throws {
        let backend = OwnedLocalBackend()
        let sibling = try LocalProcessBackend().launch(.init(
            executable: "/bin/sleep", arguments: ["30"], stdinMode: .closed,
            label: "owned-cancellation-sibling-\(UUID().uuidString)"
        ))
        let model = AppModel(store: store,
                             record: SessionRecord(projectID: ProjectID(), providerID: .codex),
                             backend: ScriptedExecutionBackend())
        model.overrideBackend = backend
        let entry = AppModel.QueuedPrompt(text: "owned local-process next entry", attachments: [])
        model.fixtureQueue = [entry]
        model.send("owned local-process cancellation fixture")
        let task = model.streamTask
        do {
            try await eventually { backend.process != nil }
            guard let process = backend.process,
                  let ownIdentity = ProcessIdentity(process.identifier),
                  let siblingIdentity = ProcessIdentity(sibling.identifier),
                  ownIdentity.parent == getpid(), siblingIdentity.parent == getpid() else {
                throw FixtureFailure.mismatch(["exact child identity/parent unavailable"])
            }
            print("Owned process PID \(ownIdentity.pid), sibling PID \(siblingIdentity.pid), parent \(getpid())")
            check(ownIdentity.isLive && siblingIdentity.isLive,
                  "local cancellation targets and sibling have verified live owned identities")
            var liveAtDispatch: Bool?
            model.onDispatch = { _ in liveAtDispatch = ownIdentity.isLive }
            model.steeringQueuedPromptID = entry.id
            model.cancel()
            try await eventuallyAsync { await backend.gate.wasRequested }
            try await Task.sleep(for: .milliseconds(100))
            check(model.dispatched.isEmpty && ownIdentity.isLive && siblingIdentity.isLive,
                  "real local Steer stays pending while owned termination is held")
            await backend.gate.release()
            await task?.value
            let exit = try await process.waitUntilExit()
            print("Owned process exit status \(exit)")
            check(liveAtDispatch == false && model.dispatched == [entry.id]
                    && !ownIdentity.isLive && !model.isRunning,
                  "actual LocalProcess exit precedes prioritized coordinator dispatch")
            check(siblingIdentity.isLive,
                  "actual cancellation leaves its independently owned sibling untouched")
            await sibling.terminate()
            let siblingExit = try await sibling.waitUntilExit()
            print("Owned sibling cleanup exit status \(siblingExit)")
            check(!siblingIdentity.isLive, "owned sibling is cleaned through its exact handle")
        } catch {
            await backend.gate.release()
            model.cancel()
            await task?.value
            if let process = backend.process {
                await process.terminate()
                _ = try? await process.waitUntilExit()
            }
            await sibling.terminate()
            _ = try? await sibling.waitUntilExit()
            throw error
        }
    }
}

private struct ProcessIdentity {
    let pid: pid_t
    let parent: pid_t
    let seconds: UInt64
    let microseconds: UInt64
    init?(_ identifier: String) {
        guard let pid = identifier.split(separator: "/").first.flatMap({ Int32($0) }) else { return nil }
        self.init(pid: pid)
    }
    private init?(pid: pid_t) {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        self.pid = pid
        parent = pid_t(info.pbi_ppid)
        seconds = info.pbi_start_tvsec
        microseconds = info.pbi_start_tvusec
    }
    var isLive: Bool {
        guard let current = Self(pid: pid) else { return false }
        return current.parent == parent && current.seconds == seconds && current.microseconds == microseconds
    }
}

private final class OwnedLocalBackend: ExecutionBackend, @unchecked Sendable {
    let id = BackendID("owned-local-cancellation-fixture")
    let displayName = "Owned cancellation fixture"
    let kind = ExecutionBackendKind.local
    let gate = TerminationGate()
    private let lock = NSLock()
    private var launched: (any ExecutionProcess)?
    var process: (any ExecutionProcess)? { lock.withLock { launched } }
    func launch(_ request: ExecutionRequest) async throws -> any ExecutionProcess {
        let process = try LocalProcessBackend().launch(.init(
            executable: "/bin/sleep", arguments: ["30"], stdinMode: .closed,
            label: "owned-cancellation-target-\(UUID().uuidString)"
        ))
        lock.withLock { launched = process }
        return DelayedTerminationProcess(base: process, gate: gate)
    }
}

private actor TerminationGate {
    var wasRequested = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        wasRequested = true
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private final class DelayedTerminationBackend: ExecutionBackend, @unchecked Sendable {
    let base: ScriptedExecutionBackend
    let gate = TerminationGate()
    var id: BackendID { base.id }
    var displayName: String { base.displayName }
    var kind: ExecutionBackendKind { base.kind }
    init(base: ScriptedExecutionBackend) { self.base = base }
    func launch(_ request: ExecutionRequest) async throws -> any ExecutionProcess {
        DelayedTerminationProcess(base: try base.launch(request), gate: gate)
    }
}

private struct DelayedTerminationProcess: ExecutionProcess {
    let base: any ExecutionProcess
    let gate: TerminationGate
    var identifier: String { base.identifier }
    var stdoutLines: AsyncThrowingStream<String, Error> { base.stdoutLines }
    var stderrLines: AsyncThrowingStream<String, Error> { base.stderrLines }
    func writeToStdin(_ data: Data) async throws { try await base.writeToStdin(data) }
    func waitUntilExit() async throws -> Int32 { try await base.waitUntilExit() }
    func terminate() async {
        await gate.wait()
        await base.terminate()
    }
}

// PRODUCTION_RESPONDER
