import Foundation

/// Owns one open session: folds relay events into transcript items, drives
/// turn state, permission auto-approval, queued prompts, notifications, and
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
        let sessionID = currentSession.id

        eventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.relay.sessionEvents(for: sessionID) {
                await self.handle(event)
            }
        }
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            for await connected in self.monitor.connectedEvents() where connected {
                self.flushQueue()
            }
        }

        Task { [weak self] in
            guard let self else { return }
            if let models = try? await self.relay.availableModels(), !models.isEmpty {
                self.availableModels = models
            } else {
                self.availableModels = AgentModel.defaultCatalog
            }
        }
    }

    /// Stops observing. Must be called explicitly — `deinit` cannot touch
    /// main-actor state.
    public func stop() {
        eventsTask?.cancel()
        eventsTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
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
            currentSession = session
            self.items = items
            isLoadingSnapshot = false

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
            upsert(.permissionRequest(record))
            if record.isPending {
                maybeAutoResolve(record)
            }

        case .turnStateChanged(let state):
            await applyTurnState(state)

        case .sessionRenamed(let title):
            currentSession.title = title

        case .sessionUpdated(let session):
            currentSession = session
        }
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

        switch state {
        case .running:
            await liveActivities.startTurnActivity(
                sessionID: currentSession.id,
                title: currentSession.title
            )
        case .idle:
            await liveActivities.endTurnActivity(sessionID: currentSession.id)
            if previous.isBusy {
                notifications.turnFinished(session: currentSession, summary: latestAssistantText)
            }
            flushQueue()
        case .awaitingPermission:
            await liveActivities.updateTurnActivity(state: state, summary: latestAssistantText)
        case .canceling, .failed:
            await liveActivities.updateTurnActivity(state: state, summary: latestAssistantText)
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

    private func maybeAutoResolve(_ record: PermissionRequestRecord) {
        guard record.isPending else { return }
        if let automatic = PermissionEvaluator.automaticDecision(
            scope: record.scope,
            mode: currentSession.configuration.permissions
        ) {
            // The relay echoes the resolved record; nothing to do locally
            // until it lands.
            Task { [weak self] in
                guard let self else { return }
                try? await self.relay.resolvePermission(
                    record.id,
                    decision: automatic,
                    in: self.currentSession.id
                )
            }
        } else {
            notifications.permissionRequested(session: currentSession, request: record)
        }
    }

    /// Answers a permission request. Choosing "Always allow" escalates the
    /// session's permission mode so future requests of this kind skip asking.
    public func resolve(_ record: PermissionRequestRecord, decision: PermissionDecision) async {
        do {
            try await relay.resolvePermission(record.id, decision: decision, in: currentSession.id)
        } catch {
            errorBanner = "Couldn't record your answer. \(error.localizedDescription)"
            return
        }

        let nextMode = PermissionEvaluator.modeAfter(
            decision: decision,
            current: currentSession.configuration.permissions
        )
        guard nextMode != currentSession.configuration.permissions else { return }
        do {
            try await relay.updateConfiguration(
                AgentConfiguration(
                    model: currentSession.configuration.model,
                    effort: currentSession.configuration.effort,
                    permissions: nextMode
                ),
                for: currentSession.id
            )
            currentSession.configuration.permissions = nextMode
        } catch {
            Log.session.error("Permission escalation failed: \(error.localizedDescription)")
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
        guard currentSession.state.acceptsNewPrompt else {
            queue.enqueue(payload, reason: .turnBusy)
            Log.composer.info("Prompt queued: turn busy")
            return
        }

        isSending = true
        defer { isSending = false }
        do {
            try await relay.sendPrompt(payload, to: currentSession.id)
        } catch {
            errorBanner = "Couldn't send — the prompt is queued and will retry."
            Log.composer.error("Send failed: \(error.localizedDescription)")
            queue.enqueue(payload, reason: .offline)
        }
    }

    private func flushQueue() {
        guard !queue.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.queue.flush(
                shouldSend: {
                    self.currentConnectionState.isConnected
                        && self.currentSession.state.acceptsNewPrompt
                },
                send: { prompt in
                    try await self.relay.sendPrompt(prompt.payload, to: self.currentSession.id)
                }
            )
        }
    }

    // MARK: - Turn control

    public func cancelTurn() async {
        guard currentSession.state.isBusy, !isCanceling else { return }
        isCanceling = true
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
