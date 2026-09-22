import Foundation

/// Persistent state of one agent conversation.
///
/// The transcript itself (`Message` values) is stored separately in an
/// append-only log; the record holds identity, configuration, and roll-up
/// statistics. `AgentSession` (the live actor) reads and writes this record
/// through the persistence store.
public struct SessionRecord: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case idle
        case running
        case failed
    }

    public var id: SessionID
    /// Owning project, or `nil` for a loose conversation.
    public var projectID: ProjectID?
    public var providerID: ProviderID
    public var modelID: ModelID?
    public var effort: ReasoningEffort?
    /// Human-facing title. `nil` until the first turn completes.
    public var title: String?
    /// Which backend the session ran on last (local / ssh:<host> / relay).
    public var backendID: BackendID?
    /// Working directory for this session (usually the project root).
    public var workingDirectory: String?
    public var status: Status
    public var createdAt: Date
    public var updatedAt: Date
    /// The provider's own session identifier, when it exposes one — used to
    /// resume a conversation on the next turn (Claude Code `--resume`,
    /// Codex thread resume).
    public var providerResumeToken: String?
    public var totalUsage: TokenUsage
    public var messageCount: Int

    public init(
        id: SessionID = SessionID(),
        projectID: ProjectID? = nil,
        providerID: ProviderID,
        modelID: ModelID? = nil,
        effort: ReasoningEffort? = nil,
        title: String? = nil,
        backendID: BackendID? = nil,
        workingDirectory: String? = nil,
        status: Status = .idle,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        providerResumeToken: String? = nil,
        totalUsage: TokenUsage = TokenUsage(),
        messageCount: Int = 0
    ) {
        self.id = id
        self.projectID = projectID
        self.providerID = providerID
        self.modelID = modelID
        self.effort = effort
        self.title = title
        self.backendID = backendID
        self.workingDirectory = workingDirectory
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerResumeToken = providerResumeToken
        self.totalUsage = totalUsage
        self.messageCount = messageCount
    }

    /// A short title derived from the first user prompt, for records that
    /// have no explicit title yet.
    public func derivedTitle(from prompt: String, maxLength: Int = 60) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "New conversation" }
        if trimmed.count <= maxLength { return trimmed }
        return String(trimmed.prefix(maxLength - 1)).trimmingCharacters(
            in: .whitespacesAndNewlines
        ) + "…"
    }
}
