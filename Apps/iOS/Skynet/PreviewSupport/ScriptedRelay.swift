import Foundation

/// A deterministic, scriptable `SkynetRelay` used by SwiftUI previews, unit
/// tests, and UI-test fixtures. Tests push events with `emit(_:to:)` and
/// inspect recorded calls afterwards.
///
/// Not for production: ships in the app target so previews compile; keep
/// references to it inside DEBUG-gated code when wiring release builds.
public final class ScriptedRelay: SkynetRelay, @unchecked Sendable {
    public struct RecordedPrompt: Equatable, Sendable {
        public let sessionID: SessionID
        public let payload: PromptPayload
    }

    public struct RecordedPermission: Equatable, Sendable {
        public let sessionID: SessionID
        public let requestID: TranscriptItemID
        public let decision: PermissionDecision
    }

    public struct RecordedRename: Equatable, Sendable {
        public let sessionID: SessionID
        public let title: String
    }

    public struct RecordedConfiguration: Equatable, Sendable {
        public let sessionID: SessionID
        public let configuration: AgentConfiguration
    }

    // MARK: - Scriptable state
    //
    // The `…Stub` properties are set by tests before subscribing; they are
    // deliberately not lock-protected.

    public let machineID: MachineID
    public var projectsStub: [Project]
    public var modelsStub: [AgentModel]
    /// Sessions per project ID.
    public var sessionsStub: [ProjectID: [AgentSession]]
    /// History replayed as the `.snapshot` event when a session opens.
    public var historyStub: [SessionID: [TranscriptItem]]
    /// Session records used for snapshots and updates.
    public var sessionsByID: [SessionID: AgentSession]
    /// When set, `sendPrompt` fails with this error instead of succeeding.
    public var promptError: Error?
    /// When set, `createSession` fails with this error.
    public var createSessionError: Error?
    /// When true, `sendPrompt` immediately emits a user message echo and a
    /// `.running` turn state.
    public var autoEchoPrompt = false

    /// Connection state pushed to subscribers; also drives `connectionEvents()`.
    public var connectionState: ConnectionState {
        get { lock.withLock { currentConnection } }
        set { pushConnection(newValue) }
    }

    // MARK: - Recording (get-only computed, backed by lock-protected storage)

    public var sentPrompts: [RecordedPrompt] {
        lock.withLock { sentPromptsStorage }
    }
    public var permissionDecisions: [RecordedPermission] {
        lock.withLock { permissionDecisionsStorage }
    }
    public var renameCalls: [RecordedRename] {
        lock.withLock { renameCallsStorage }
    }
    public var deleteCalls: [SessionID] {
        lock.withLock { deleteCallsStorage }
    }
    public var configurationUpdates: [RecordedConfiguration] {
        lock.withLock { configurationUpdatesStorage }
    }
    public var reconnectCallCount: Int {
        lock.withLock { reconnectCallCountStorage }
    }
    public var cancelCalls: [SessionID] {
        lock.withLock { cancelCallsStorage }
    }

    // MARK: - Internals

    private let lock = NSLock()
    private var currentConnection: ConnectionState
    private let connectionChannel = EventChannel<ConnectionState>(replaysLastValue: true)
    private var sessionChannels: [SessionID: EventChannel<SessionEvent>] = [:]
    /// Events emitted before any subscriber attached; replayed after the
    /// snapshot to the first subscriber.
    private var pendingEvents: [SessionID: [SessionEvent]] = [:]

    private var sentPromptsStorage: [RecordedPrompt] = []
    private var permissionDecisionsStorage: [RecordedPermission] = []
    private var renameCallsStorage: [RecordedRename] = []
    private var deleteCallsStorage: [SessionID] = []
    private var configurationUpdatesStorage: [RecordedConfiguration] = []
    private var reconnectCallCountStorage = 0
    private var cancelCallsStorage: [SessionID] = []

    public init(
        machineID: MachineID = MachineID("preview-mac"),
        connectionState: ConnectionState = .connected,
        projects: [Project] = [],
        models: [AgentModel] = AgentModel.defaultCatalog,
        sessions: [AgentSession] = [],
        history: [SessionID: [TranscriptItem]] = [:]
    ) {
        self.machineID = machineID
        self.currentConnection = connectionState
        self.projectsStub = projects
        self.modelsStub = models
        var byProject: [ProjectID: [AgentSession]] = [:]
        var byID: [SessionID: AgentSession] = [:]
        for session in sessions {
            byProject[session.projectID, default: []].append(session)
            byID[session.id] = session
        }
        self.sessionsStub = byProject
        self.sessionsByID = byID
        self.historyStub = history
        self.connectionChannel.send(connectionState)
    }

    // MARK: - Event injection (test/preview API)

    /// Pushes a live event to all subscribers of `sessionID`.
    public func emit(_ event: SessionEvent, to sessionID: SessionID) {
        let channel: EventChannel<SessionEvent>? = lock.withLock {
            if let channel = sessionChannels[sessionID] {
                return channel
            }
            pendingEvents[sessionID, default: []].append(event)
            return nil
        }
        channel?.send(event)
    }

    public func pushConnection(_ state: ConnectionState) {
        lock.withLock { currentConnection = state }
        connectionChannel.send(state)
    }

    /// Convenience: append an item to a session's live feed.
    public func emitItem(_ item: TranscriptItem, to sessionID: SessionID) {
        emit(.itemAppended(item), to: sessionID)
    }

    // MARK: - SkynetRelay

    public func connectionEvents() -> AsyncStream<ConnectionState> {
        connectionChannel.stream()
    }

    public func reconnect() async {
        lock.withLock { reconnectCallCountStorage += 1 }
        // Scripted relays reconnect instantly; tests drive the state machine.
        pushConnection(.connected)
    }

    public func projects() async throws -> [Project] {
        lock.withLock { projectsStub }
    }

    public func sessions(in project: ProjectID) async throws -> [AgentSession] {
        lock.withLock {
            (sessionsStub[project] ?? []).sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    public func createSession(
        in project: ProjectID,
        configuration: AgentConfiguration
    ) async throws -> AgentSession {
        if let createSessionError { throw createSessionError }
        let session = AgentSession(
            id: SessionID("session-\(UUID().uuidString.prefix(8).lowercased())"),
            projectID: project,
            title: "New session",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            configuration: configuration
        )
        lock.withLock {
            sessionsStub[project, default: []].append(session)
            sessionsByID[session.id] = session
            historyStub[session.id] = []
        }
        return session
    }

    public func renameSession(_ sessionID: SessionID, to title: String) async throws {
        let channel: EventChannel<SessionEvent>? = lock.withLock {
            renameCallsStorage.append(RecordedRename(sessionID: sessionID, title: title))
            if var session = sessionsByID[sessionID] {
                session.title = title
                sessionsByID[sessionID] = session
            }
            return sessionChannels[sessionID]
        }
        channel?.send(.sessionRenamed(title))
    }

    public func deleteSession(_ sessionID: SessionID) async throws {
        let channel: EventChannel<SessionEvent>? = lock.withLock {
            deleteCallsStorage.append(sessionID)
            if let session = sessionsByID[sessionID] {
                sessionsStub[session.projectID]?.removeAll { $0.id == sessionID }
                sessionsByID[sessionID] = nil
            }
            historyStub[sessionID] = nil
            let channel = sessionChannels[sessionID]
            sessionChannels[sessionID] = nil
            return channel
        }
        channel?.finish()
    }

    public func availableModels() async throws -> [AgentModel] {
        lock.withLock { modelsStub }
    }

    public func updateConfiguration(
        _ configuration: AgentConfiguration,
        for sessionID: SessionID
    ) async throws {
        let (channel, updatedSession): (EventChannel<SessionEvent>?, AgentSession?) = lock.withLock {
            configurationUpdatesStorage.append(
                RecordedConfiguration(sessionID: sessionID, configuration: configuration)
            )
            if var session = sessionsByID[sessionID] {
                session.configuration = configuration
                sessionsByID[sessionID] = session
                return (sessionChannels[sessionID], session)
            }
            return (nil, nil)
        }
        if let channel, let updatedSession {
            channel.send(.sessionUpdated(updatedSession))
        }
    }

    public func sessionEvents(for sessionID: SessionID) -> AsyncStream<SessionEvent> {
        let (channel, prefix): (EventChannel<SessionEvent>, [SessionEvent]) = lock.withLock {
            let channel: EventChannel<SessionEvent>
            if let existing = sessionChannels[sessionID] {
                channel = existing
            } else {
                channel = EventChannel<SessionEvent>(buffersWhenIdle: true)
                sessionChannels[sessionID] = channel
            }
            let items = historyStub[sessionID] ?? []
            let session = sessionsByID[sessionID]
                ?? AgentSession(id: sessionID, projectID: ProjectID("preview"), title: "Session")
            let snapshot = SessionEvent.snapshot(session: session, items: items)
            let replay = pendingEvents[sessionID] ?? []
            pendingEvents[sessionID] = nil
            return (channel, [snapshot] + replay)
        }

        // Every subscriber gets its own snapshot prefix, then the live feed;
        // the channel handles ordering and idle buffering.
        return channel.stream(prefix: prefix)
    }

    public func sendPrompt(_ prompt: PromptPayload, to sessionID: SessionID) async throws {
        if let promptError { throw promptError }
        let channel: EventChannel<SessionEvent>? = lock.withLock {
            sentPromptsStorage.append(RecordedPrompt(sessionID: sessionID, payload: prompt))
            return sessionChannels[sessionID]
        }
        if autoEchoPrompt, let channel {
            channel.send(.itemAppended(.userMessage(
                UserMessage(
                    id: TranscriptItemID("echo-\(UUID().uuidString.prefix(8))"),
                    text: prompt.text,
                    attachments: prompt.attachments
                )
            )))
            channel.send(.turnStateChanged(.running))
        }
    }

    public func cancelCurrentTurn(in sessionID: SessionID) async throws {
        let channel: EventChannel<SessionEvent>? = lock.withLock {
            cancelCallsStorage.append(sessionID)
            return sessionChannels[sessionID]
        }
        channel?.send(.turnStateChanged(.idle))
    }

    public func resolvePermission(
        _ requestID: TranscriptItemID,
        decision: PermissionDecision,
        in sessionID: SessionID
    ) async throws {
        let (channel, record): (EventChannel<SessionEvent>?, PermissionRequestRecord?) = lock.withLock {
            permissionDecisionsStorage.append(
                RecordedPermission(sessionID: sessionID, requestID: requestID, decision: decision)
            )
            let channel = sessionChannels[sessionID]
            var updated: PermissionRequestRecord?
            if var items = historyStub[sessionID] {
                items = items.map { item in
                    guard case .permissionRequest(var record) = item, record.id == requestID else {
                        return item
                    }
                    record.decision = decision
                    updated = record
                    return .permissionRequest(record)
                }
                historyStub[sessionID] = items
            }
            return (channel, updated)
        }

        let resolvedRecord = record ?? PermissionRequestRecord(
            id: requestID,
            summary: "Permission request",
            decision: decision
        )
        channel?.send(.permissionUpdated(resolvedRecord))
    }

    // MARK: - Test helpers

    public func recordFor(sessionID: SessionID) -> AgentSession? {
        lock.withLock { sessionsByID[sessionID] }
    }
}
