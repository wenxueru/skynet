import Foundation
import SkynetCore

/// One provider turn's preparation, event consumption and activity drain.
/// AppModel retains queue/approval ownership; ordinary and scheduled paths
/// deliberately keep different completion and cancellation semantics.
@MainActor
final class SessionTurnExecutor {
    struct OrdinaryCallbacks {
        var started: () -> Void
        var receive: (AgentEvent) -> Void
        var updateRecord: (SessionRecord) -> Void
        var failed: (Error, Bool) -> Void
    }

    struct ScheduledResult {
        let record: SessionRecord
        let completedSuccessfully: Bool
        let failure: SkynetError?
    }

    let session: AgentSession
    private let record: SessionRecord
    private let provider: AgentProviderDescriptor

    init(record: SessionRecord, configuration: AgentSession.Configuration) throws {
        self.record = record
        provider = configuration.provider
        session = try AgentSession(record: record, configuration: configuration)
    }

    func runOrdinary(
        _ prompt: String, attachments: [ImageAttachment],
        referenceSessions: [SessionRecord], store: JSONDiskStore,
        activityStart: Date, callbacks: OrdinaryCallbacks
    ) async -> Bool {
        var didStartTurn = false
        var completedTurn = false
        var activityReader: CodexSubagentActivityReader?
        var activityTask: Task<Void, Never>?
        do {
            try await session.loadPersistedTranscript()
            let expandedPrompt = await Task.detached(priority: .userInitiated) {
                SessionReferenceContext.expand(prompt, sessions: referenceSessions) { id in
                    try? store.loadMessages(for: id)
                }
            }.value
            try Task.checkCancellation()
            activityReader = await SessionTranscriptDiscovery.codexActivityReader(
                for: record, provider: provider, notBefore: activityStart, startAtEnd: true
            )
            try Task.checkCancellation()
            if let activityReader {
                activityTask = Task {
                    await self.observeSubagentActivity(activityReader, receive: callbacks.receive)
                }
            }
            let stream = try await session.send(expandedPrompt, attachments: attachments)
            didStartTurn = true
            callbacks.started()
            for try await event in stream {
                callbacks.receive(event)
                if case .sessionTokenReceived(let token) = event, activityReader == nil {
                    // A new/forked parent didn't have a rollout before launch.
                    // Fresh task_started + parent/turn checks exclude older data.
                    var source = record
                    source.providerResumeToken = token
                    source.forkSourceToken = nil
                    activityReader = await SessionTranscriptDiscovery.codexActivityReader(
                        for: source, provider: provider, notBefore: activityStart, startAtEnd: false
                    )
                    if let activityReader {
                        activityTask = Task {
                            await self.observeSubagentActivity(activityReader, receive: callbacks.receive)
                        }
                    }
                }
                if case .turnCompleted(let summary) = event {
                    completedTurn = summary.stopReason == .completed
                }
            }
            let updated = await session.record
            callbacks.updateRecord(updated)
        } catch {
            callbacks.failed(error, didStartTurn)
        }
        // Consumer cancellation alone does not mean the provider finished
        // cleanup. Drain the original turn before defer dispatches Steer.
        if Task.isCancelled { await session.cancelActiveTurn() }
        activityTask?.cancel()
        await activityTask?.value
        if !Task.isCancelled, let activityReader {
            await observeSubagentActivity(activityReader, receive: callbacks.receive, keepWatching: false)
        }

        return completedTurn
    }

    func runScheduled(_ prompt: String) async throws -> ScheduledResult {
        try await session.loadPersistedTranscript()
        try Task.checkCancellation()
        let stream = try await session.send(prompt)
        var completedSuccessfully = false
        var turnFailure: SkynetError?
        for try await event in stream {
            if case .turnCompleted(let summary) = event {
                completedSuccessfully = summary.stopReason == .completed
            } else if case .turnFailed(let failure) = event {
                turnFailure = failure.error
            }
        }
        try Task.checkCancellation()
        let updated = await session.record
        return ScheduledResult(record: updated, completedSuccessfully: completedSuccessfully, failure: turnFailure)
    }

    private func observeSubagentActivity(
        _ reader: CodexSubagentActivityReader, receive: (AgentEvent) -> Void, keepWatching: Bool = true
    ) async {
        // Advisory source failure must not fail an otherwise healthy provider
        // turn. Drain/cancel this task before dispatching any queued successor.
        do {
            while true {
                try Task.checkCancellation()
                let page = try await reader.readNext()
                try Task.checkCancellation()
                for report in page.reports { receive(.subagentStatusReported(report)) }
                if page.isFinished || (!keepWatching && !page.hasMore) { return }
                if page.hasMore {
                    await Task.yield()
                } else {
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
        } catch { /* stdout remains the primary event source */ }
    }

}
