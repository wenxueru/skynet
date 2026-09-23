import Foundation

/// Persistent state of one agent conversation.
///
/// The transcript itself (`Message` values) is stored separately in an
/// append-only log; the record holds identity, configuration, and roll-up
/// statistics. `AgentSession` (the live actor) reads and writes this record
/// through the persistence store.
public struct SessionRecord: Codable, Hashable, Sendable, Identifiable {
    public enum PinMode: String, Codable, Hashable, Sendable {
        case project
        case global
    }
    public enum CodexApprovalMode: String, Codable, Hashable, Sendable {
        case manual
        case automatic
    }
    public enum ClaudePermissionMode: String, Codable, Hashable, Sendable, CaseIterable {
        case manual
        case acceptEdits
        case plan
        case auto
        case dontAsk
        case bypassPermissions
    }
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
    /// Coarse tool permission policy selected for this conversation.
    /// `nil` preserves the provider's safe default used by older records.
    public var permissionEffect: PermissionRule.Effect?
    /// Explicit Codex reviewer choice. Nil keeps older sessions' policy intact.
    public var codexApprovalMode: CodexApprovalMode?
    /// Per-session Codex Fast mode override. Nil follows the user's Codex config.
    public var codexFastMode: Bool?
    /// Claude Code's native `--permission-mode`; nil keeps older sessions' policy.
    public var claudePermissionMode: ClaudePermissionMode?
    /// Hidden from the active sidebar, but retained in Skynet storage.
    public var isArchived: Bool?
    /// Set for sessions archived through the provider; nil also covers older Skynet-only archives.
    public var archivedInProvider: Bool?
    /// Sidebar placement only; does not alter the provider conversation.
    public var pinMode: PinMode?
    /// An explicit unread marker, cleared when the conversation is opened.
    public var markedUnreadAt: Date?
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
    /// Claude Code fork source until the first child turn returns its new native ID.
    public var forkSourceToken: String?
    public var totalUsage: TokenUsage
    public var messageCount: Int

    public init(
        id: SessionID = SessionID(),
        projectID: ProjectID? = nil,
        providerID: ProviderID,
        modelID: ModelID? = nil,
        effort: ReasoningEffort? = nil,
        permissionEffect: PermissionRule.Effect? = nil,
        codexApprovalMode: CodexApprovalMode? = nil,
        codexFastMode: Bool? = nil,
        claudePermissionMode: ClaudePermissionMode? = nil,
        isArchived: Bool? = nil,
        archivedInProvider: Bool? = nil,
        pinMode: PinMode? = nil,
        markedUnreadAt: Date? = nil,
        title: String? = nil,
        backendID: BackendID? = nil,
        workingDirectory: String? = nil,
        status: Status = .idle,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        providerResumeToken: String? = nil,
        forkSourceToken: String? = nil,
        totalUsage: TokenUsage = TokenUsage(),
        messageCount: Int = 0
    ) {
        self.id = id
        self.projectID = projectID
        self.providerID = providerID
        self.modelID = modelID
        self.effort = effort
        self.permissionEffect = permissionEffect
        self.codexApprovalMode = codexApprovalMode
        self.codexFastMode = codexFastMode
        self.claudePermissionMode = claudePermissionMode
        self.isArchived = isArchived
        self.archivedInProvider = archivedInProvider
        self.pinMode = pinMode
        self.markedUnreadAt = markedUnreadAt
        self.title = title
        self.backendID = backendID
        self.workingDirectory = workingDirectory
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerResumeToken = providerResumeToken
        self.forkSourceToken = forkSourceToken
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
