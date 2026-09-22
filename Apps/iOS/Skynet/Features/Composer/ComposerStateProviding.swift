import Foundation

/// Bridge between the composer (and its controls) and whatever owns session
/// state. Implemented by `SessionViewModel`; this protocol lets the composer
/// compile and test independently of the session feature.
@MainActor
public protocol ComposerStateProviding: AnyObject {
    // MARK: Read-only state surfaced in the composer chrome

    var currentTurnState: TurnState { get }
    var currentConnectionState: ConnectionState { get }
    var currentConfiguration: AgentConfiguration { get }
    var queuedPromptCount: Int { get }
    var queuedPrompts: [QueuedPrompt] { get }
    var isQueueFlushing: Bool { get }
    var availableModels: [AgentModel] { get }

    // MARK: Actions

    /// Send immediately; the owner decides whether that is possible.
    func composerDidRequestSend(_ payload: PromptPayload)

    /// Explicitly queue the payload for later.
    func composerDidRequestQueue(_ payload: PromptPayload)

    func composerDidChangeConfiguration(_ configuration: AgentConfiguration)

    /// Send one specific queued entry right now (bypasses FIFO order).
    func composerDidRequestSendQueuedPrompt(id: UUID)

    func composerDidRequestRemoveQueuedPrompt(id: UUID)
}
