import Foundation

/// The stream of things that happen while a turn runs.
///
/// Events are ephemeral: the UI consumes them live, the notification router
/// watches a subset, and anything worth keeping is folded into `Message`
/// values and persisted. Unknown provider output is *not* dropped — it
/// surfaces as `.unhandledEvent` so new provider features degrade to raw
/// JSON instead of vanishing.
public enum AgentEvent: Sendable {
    /// A turn (one user prompt → final answer) began.
    case turnStarted(TurnContext)
    /// The provider reported its own session identifier for this
    /// conversation, enabling later resume.
    case sessionTokenReceived(providerSessionID: String)
    /// Incremental visible answer text.
    case textDelta(String)
    /// Incremental reasoning text.
    case thinkingDelta(String)
    /// A complete message (any origin) was produced. Persisted transcripts
    /// are built from these.
    case messageCompleted(Message)
    /// The agent requested a tool invocation. Execution happens inside the
    /// agent CLI; permission gating happened before launch.
    case toolCallStarted(ToolCall)
    /// A tool invocation finished.
    case toolCallCompleted(ToolCallResult)
    /// A tool invocation needs an explicit human decision. Only sent when
    /// the provider actually supports interactive asks; the permission
    /// policy's automatic verdicts never surface as events.
    case permissionRequested(PermissionRequest)
    /// Token accounting for the turn so far.
    case usageReported(TokenUsage)
    /// A provider output frame SkynetCore does not model.
    case unhandledEvent(raw: JSONValue)
    /// The turn finished successfully.
    case turnCompleted(TurnSummary)
    /// The turn failed. The session record is marked `.failed` but remains
    /// usable — a new turn may recover.
    case turnFailed(TurnFailure)
}

/// Identity shared by every event of one turn.
public struct TurnContext: Hashable, Sendable {
    public var turnID: UUID
    public var sessionID: SessionID
    public var providerID: ProviderID
    public var modelID: ModelID?

    public init(
        turnID: UUID = UUID(),
        sessionID: SessionID,
        providerID: ProviderID,
        modelID: ModelID? = nil
    ) {
        self.turnID = turnID
        self.sessionID = sessionID
        self.providerID = providerID
        self.modelID = modelID
    }
}

/// The outcome of a completed tool invocation.
public struct ToolCallResult: Hashable, Sendable {
    public var toolCallID: ToolCallID
    /// Rendered output of the tool (text; providers flatten binary output).
    public var content: String
    public var isError: Bool

    public init(toolCallID: ToolCallID, content: String, isError: Bool) {
        self.toolCallID = toolCallID
        self.content = content
        self.isError = isError
    }
}

/// Roll-up of a finished turn.
public struct TurnSummary: Hashable, Sendable {
    public enum StopReason: String, Sendable {
        /// The agent produced a final answer.
        case completed
        /// The user (or system) cancelled mid-turn.
        case cancelled
        /// The provider ended the turn for its own reason (refusal, limit).
        case stopped
    }

    public var context: TurnContext
    public var stopReason: StopReason
    /// The final answer text, when there was one.
    public var finalText: String?
    public var usage: TokenUsage?
    public var duration: TimeInterval?

    public init(
        context: TurnContext,
        stopReason: StopReason,
        finalText: String? = nil,
        usage: TokenUsage? = nil,
        duration: TimeInterval? = nil
    ) {
        self.context = context
        self.stopReason = stopReason
        self.finalText = finalText
        self.usage = usage
        self.duration = duration
    }
}

/// Why a turn failed.
public struct TurnFailure: Hashable, Sendable {
    public var context: TurnContext
    public var error: SkynetError

    public init(context: TurnContext, error: SkynetError) {
        self.context = context
        self.error = error
    }
}
