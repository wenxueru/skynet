import Foundation

/// The single boundary between this app and any agent runtime.
///
/// ## Design rule
/// The iOS app **never spawns or runs a coding agent locally**. There is no
/// process spawning anywhere in this module. All agent execution happens on a
/// paired Mac and reaches the device exclusively through a `SkynetRelay`
/// implementation. Integrators provide the concrete transport — for example a
/// WebSocket client speaking to a relay on the paired Mac, or a bridge into
/// `SkynetCore`. Everything in the app is written against this protocol, so
/// swapping transports never touches feature code.
///
/// ## Contract notes for implementors
/// - All methods are safe to call from any actor; callbacks surface on the
///   caller's task.
/// - `sessionEvents(for:)` must emit exactly one `.snapshot` before any
///   incremental event, and replayed snapshots must already include every
///   item the session had at subscription time.
/// - `connectionEvents()` should replay the current state on subscription so
///   late subscribers render correct UI immediately.
public protocol SkynetRelay: Sendable {
    /// The machine this relay is bound to.
    var machineID: MachineID { get }

    /// Live connection state. Implementations should replay the current value.
    func connectionEvents() -> AsyncStream<ConnectionState>

    /// Ask the transport to re-establish its link (used by reconnect logic).
    func reconnect() async

    // MARK: Library

    func projects() async throws -> [Project]
    func sessions(in project: ProjectID) async throws -> [AgentSession]

    /// Creates a new session and returns its initial state.
    func createSession(
        in project: ProjectID,
        configuration: AgentConfiguration
    ) async throws -> AgentSession

    func renameSession(_ sessionID: SessionID, to title: String) async throws
    func deleteSession(_ sessionID: SessionID) async throws

    // MARK: Session interaction

    /// Model catalog currently offered for new sessions on this machine.
    func availableModels() async throws -> [AgentModel]

    func updateConfiguration(
        _ configuration: AgentConfiguration,
        for sessionID: SessionID
    ) async throws

    /// Event stream for a session; begins with `.snapshot`.
    func sessionEvents(for sessionID: SessionID) -> AsyncStream<SessionEvent>

    /// Sends a prompt for the agent's next (or current) turn.
    func sendPrompt(_ prompt: PromptPayload, to sessionID: SessionID) async throws

    /// Stops the in-flight turn.
    func cancelCurrentTurn(in sessionID: SessionID) async throws

    /// Answers a pending permission request.
    func resolvePermission(
        _ requestID: TranscriptItemID,
        decision: PermissionDecision,
        in sessionID: SessionID
    ) async throws
}

/// Events delivered for an open session. Ordered per session; cross-session
/// ordering is not guaranteed.
public enum SessionEvent: Equatable, Sendable {
    /// Full state at subscription time.
    case snapshot(session: AgentSession, items: [TranscriptItem])
    /// A new item was appended to the transcript.
    case itemAppended(TranscriptItem)
    /// A chunk of text arrived for a streaming assistant message.
    case messageDelta(itemID: TranscriptItemID, text: String)
    /// The streaming message is complete.
    case messageCompleted(itemID: TranscriptItemID)
    /// A tool call record was added or updated (state, output, duration…).
    case toolCallUpdated(ToolCallRecord)
    /// A permission request was added or its decision changed.
    case permissionUpdated(PermissionRequestRecord)
    /// The session's turn state changed.
    case turnStateChanged(TurnState)
    /// The session title changed (rename can be initiated from the Mac too).
    case sessionRenamed(String)
    /// General session metadata refresh (preview, unread, configuration…).
    case sessionUpdated(AgentSession)
}
