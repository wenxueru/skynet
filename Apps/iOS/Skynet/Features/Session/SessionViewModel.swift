import SkynetMobile
import Foundation

/// Owns one open session: folds relay events into transcript items, drives
/// turn state, explicit approvals, queued prompts, notifications, and
/// live activities. The transcript is relay-authoritative — local sends never
/// insert items, the relay echoes them, so there are no duplicates.
///
/// The view model conforms to `ComposerStateProviding` so the composer and
/// its controls stay decoupled from session internals.
@MainActor
@Observable
public final class SessionViewModel: ComposerStateProviding {
    /// Immutable identity of the session this model was opened with.
    public let session: AgentSession

    // MARK: Observable state

    /// Live session record; updated by every session-level event.
    public private(set) var currentSession: AgentSession
    public private(set) var items: [TranscriptItem] = []
    public private(set) var isLoadingSnapshot = true
    public private(set) var isSending = false
    public private(set) var isCanceling = false
    /// Bumped for events that arrive while the session's screen is not
    /// visible; cleared on return.
    public private(set) var unreadCount = 0
    public private(set) var isViewVisible = false
    public private(set) var errorBanner: String?

    public let queue = QueuedPromptsModel()

    private let notifications: TurnNotificationCoordinator
    private let relay: any SkynetRelay
    private let monitor: ConnectionMonitorModel
    private let liveActivities: any LiveActivityPresenting
    private let activityState: AppActivityState

    private var eventsTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var modelsTask: Task<Void, Never>?
    private var queueFlushTask: Task<Void, Never>?
    private var observationGeneration = 0
    private var hasSnapshot = false
    private var snapshotError: String?
    private var queueRequiresReview = false

    public private(set) var availableModels: [AgentModel] = []

    public init(
        session: AgentSession,
        relay: any SkynetRelay,
        monitor: ConnectionMonitorModel,
        notifications: any AppNotificationScheduling,
        liveActivities: any LiveActivityPresenting,
        activityState: AppActivityState
    ) {
        self.session = session
        self.currentSession = session
        self.relay = relay
        self.monitor = monitor
        self.liveActivities = liveActivities
        self.activityState = activityState
        self.notifications = TurnNotificationCoordinator(
            activity: activityState,
            scheduler: notifications
        )
    }

    // MARK: - Lifecycle

    /// Subscribes to the session's event stream and connection signals.
    /// Idempotent; pair with `stop()` when the screen goes away for good.
    public func start() {
        guard eventsTask == nil else { return }
        observationGeneration += 1
        let sessionID = currentSession.id

        eventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.relay.sessionEvents(for: sessionID) {
                guard !Task.isCancelled else { break }
                await self.handle(event)
            }
        }
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            for await connected in self.monitor.connectedEvents() where connected {
                guard !Task.isCancelled else { break }
                self.flushQueue()
            }
        }

        modelsTask = Task { [weak self] in
            guard let self else { return }
            if let models = try? await self.relay.availableModels(), !models.isEmpty {
                guard !Task.isCancelled else { return }
                self.availableModels = models
            }
        }
    }

    /// Stops observing. Must be called explicitly — `deinit` cannot touch
    /// main-actor state.
    public func stop() {
        observationGeneration += 1
        eventsTask?.cancel()
        eventsTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        modelsTask?.cancel()
        modelsTask = nil
        queueFlushTask?.cancel()
        queueFlushTask = nil
    }

    /// Tracks screen visibility for unread counts and notification clearing.
    public func setViewVisible(_ visible: Bool) {
        isViewVisible = visible
        if visible {
            unreadCount = 0
            notifications.clear(for: currentSession.id)
        }
    }

    // MARK: - Event folding

    private func handle(_ event: SessionEvent) async {
        switch event {
        case .snapshot(let session, let items):
            let previousState = currentSession.state
            let previousPending = Set(self.items.compactMap { item -> TranscriptItemID? in
                if case .permissionRequest(let request) = item, request.isPending { return request.id }
                return nil
            })
            currentSession = session
            self.items = items
            isLoadingSnapshot = false
            clearSnapshotError()
            if hasSnapshot {
                currentSession.state = previousState
                await applyTurnState(session.state)
                for item in items {
                    if case .permissionRequest(let request) = item,
                       request.isPending, !previousPending.contains(request.id) {
                        notifications.permissionRequested(session: session, request: request)
                    }
                }
            }
            hasSnapshot = true
            if session.state == .idle { flushQueue() }

        case .loadFailed(let detail):
            isLoadingSnapshot = false
            snapshotError = "Couldn't update the conversation. \(detail)"
            errorBanner = snapshotError

        case .itemAppended(let item):
            upsert(item)

        case .messageDelta(let itemID, let text):
            let updated = updateAssistant(id: itemID) { message in
                message.text += text
                message.isStreaming = true
            }
            if !updated {
                // Deltas without a preceding itemAppended: tolerate rather
                // than drop.
                upsert(.assistantMessage(AssistantMessage(
                    id: itemID,
                    text: text,
                    isStreaming: true
                )))
            }

        case .messageCompleted(let itemID):
            _ = updateAssistant(id: itemID) { message in
                message.isStreaming = false
            }

        case .toolCallUpdated(let record):
            upsert(.toolCall(record))

        case .permissionUpdated(let record):
            let wasPending = items.contains {
                if case .permissionRequest(let old) = $0 { return old.id == record.id && old.isPending }
                return false
            }
            upsert(.permissionRequest(record))
            if record.isPending && !wasPending {
                notifications.permissionRequested(session: currentSession, request: record)
            }

        case .turnStateChanged(let state):
            await applyTurnState(state)

        case .sessionRenamed(let title):
            currentSession.title = title

        case .sessionUpdated(let session):
            clearSnapshotError()
            let previousState = currentSession.state
            currentSession = session
            currentSession.state = previousState
            await applyTurnState(session.state)
        }
    }

    private func clearSnapshotError() {
        if errorBanner == snapshotError { errorBanner = nil }
        snapshotError = nil
    }

    private func upsert(_ item: TranscriptItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
            if !isViewVisible {
                unreadCount += 1
            }
        }
    }

    @discardableResult
    private func updateAssistant(
        id: TranscriptItemID,
        _ mutate: (inout AssistantMessage) -> Void
    ) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .assistantMessage(var message) = items[index] else {
            return false
        }
        mutate(&message)
        items[index] = .assistantMessage(message)
        return true
    }

    private func applyTurnState(_ state: TurnState) async {
        let previous = currentSession.state
        currentSession.state = state
        guard previous != state else { return }

        switch state {
        case .running:
            await liveActivities.startTurnActivity(
                sessionID: currentSession.id,
                title: currentSession.title
            )
        case .idle:
            await liveActivities.endTurnActivity(sessionID: currentSession.id)
            if previous == .running || previous == .awaitingPermission {
                notifications.turnFinished(session: currentSession, summary: latestAssistantText)
            }
            flushQueue()
        case .awaitingPermission:
            await liveActivities.updateTurnActivity(state: state, summary: latestAssistantText)
        case .canceling:
            queueRequiresReview = true
            await liveActivities.updateTurnActivity(state: state, summary: latestAssistantText)
        case .failed:
            queueRequiresReview = true
            await liveActivities.endTurnActivity(sessionID: currentSession.id)
        }
    }

    private var latestAssistantText: String? {
        for item in items.reversed() {
            if case .assistantMessage(let message) = item, !message.text.isEmpty {
                return message.text
            }
        }
        return nil
    }

    // MARK: - Permissions

    /// Answers only this Mac-issued request; device UI never escalates policy.
    public func resolve(_ record: PermissionRequestRecord, decision: PermissionDecision) async {
        guard decision != .approvedAlways else {
            errorBanner = "Persistent approval is available on your Mac."
            return
        }
        do {
            try await relay.resolvePermission(record.id, decision: decision, in: currentSession.id)
        } catch {
            errorBanner = "Couldn't record your answer. \(error.localizedDescription)"
        }
    }

    // MARK: - ComposerStateProviding

    public var currentTurnState: TurnState { currentSession.state }
    public var currentConnectionState: ConnectionState { monitor.state }
    public var currentConfiguration: AgentConfiguration { currentSession.configuration }
    public var queuedPromptCount: Int { queue.count }
    public var queuedPrompts: [QueuedPrompt] { queue.prompts }
    public var isQueueFlushing: Bool { queue.isFlushing }

    public func composerDidRequestSend(_ payload: PromptPayload) {
        Task { await send(payload) }
    }

    public func composerDidRequestQueue(_ payload: PromptPayload) {
        queue.enqueue(payload, reason: .userRequested)
    }

    public func composerDidChangeConfiguration(_ configuration: AgentConfiguration) {
        guard configuration.permissions == .askForEverything else {
            errorBanner = "Permission policy is controlled on your Mac. Mobile requests use Ask Always."
            return
        }
        Task {
            do {
                try await relay.updateConfiguration(configuration, for: currentSession.id)
                currentSession.configuration = configuration
            } catch {
                errorBanner = "Couldn't update settings. \(error.localizedDescription)"
            }
        }
    }

    public func composerDidRequestSendQueuedPrompt(id: UUID) {
        guard let entry = queue.take(id) else { return }
        Task { await send(entry.payload) }
    }

    public func composerDidRequestRemoveQueuedPrompt(id: UUID) {
        queue.remove(id)
    }

    // MARK: - Sending

    /// Sends immediately when the link is up and the turn is free; otherwise
    /// queues with the reason that blocked it.
    public func send(_ payload: PromptPayload) async {
        guard !payload.isEffectivelyEmpty else { return }

        guard currentConnectionState.isConnected else {
            queue.enqueue(payload, reason: .offline)
            Log.composer.info("Prompt queued: offline")
            return
        }
        guard hasSnapshot, currentSession.state.acceptsNewPrompt, !isSending, !queue.isFlushing else {
            queue.enqueue(payload, reason: .turnBusy)
            Log.composer.info("Prompt queued: turn busy")
            return
        }

        isSending = true
        defer { isSending = false }
        do {
            try await relay.sendPrompt(payload, to: currentSession.id)
            queueRequiresReview = false
            await applyTurnState(.running)
        } catch {
            queueRequiresReview = true
            errorBanner = "Couldn't confirm delivery. The prompt is queued for review. \(error.localizedDescription)"
            Log.composer.error("Send failed: \(error.localizedDescription)")
            queue.enqueue(payload, reason: .offline)
        }
    }

    private func flushQueue() {
        guard eventsTask != nil, queueFlushTask == nil,
              !queue.isEmpty, hasSnapshot, !queueRequiresReview else { return }
        let generation = observationGeneration
        queueFlushTask = Task { [weak self] in
            guard let self, !Task.isCancelled, generation == self.observationGeneration else { return }
            defer {
                if generation == self.observationGeneration { self.queueFlushTask = nil }
            }
            await self.queue.flush(
                shouldSend: {
                    !Task.isCancelled && generation == self.observationGeneration
                        && self.eventsTask != nil && self.currentConnectionState.isConnected
                        && self.currentSession.state == .idle && !self.isSending
                        && !self.queueRequiresReview
                },
                send: { prompt in
                    do {
                        try await self.relay.sendPrompt(prompt.payload, to: self.currentSession.id)
                        if generation == self.observationGeneration, !Task.isCancelled {
                            await self.applyTurnState(.running)
                        }
                    } catch {
                        self.queueRequiresReview = true
                        throw error
                    }
                }
            )
        }
    }

    // MARK: - Turn control

    public func cancelTurn() async {
        guard currentSession.state.isBusy, !isCanceling else { return }
        isCanceling = true
        queueRequiresReview = true
        defer { isCanceling = false }
        do {
            try await relay.cancelCurrentTurn(in: currentSession.id)
        } catch {
            errorBanner = "Couldn't cancel the turn. \(error.localizedDescription)"
        }
    }

    // MARK: - Rename

    public func rename(to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentSession.title else { return }
        do {
            try await relay.renameSession(currentSession.id, to: trimmed)
            currentSession.title = trimmed
        } catch {
            errorBanner = "Couldn't rename the session. \(error.localizedDescription)"
        }
    }

    // MARK: - Misc

    public func dismissError() {
        errorBanner = nil
    }
}
