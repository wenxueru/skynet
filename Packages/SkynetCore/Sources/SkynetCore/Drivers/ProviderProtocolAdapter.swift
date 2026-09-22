import Foundation

/// What one turn asks of the provider.
public struct AgentTurnRequest: Hashable, Sendable {
    public var turnID: UUID
    public var sessionID: SessionID
    public var providerID: ProviderID
    public var prompt: String
    public var attachments: [ImageAttachment]
    public var modelID: ModelID?
    public var effort: ReasoningEffort?
    public var workingDirectory: String?
    /// Provider-side conversation token (`--resume`), when one is known.
    public var resumeToken: String?

    public init(
        turnID: UUID = UUID(),
        sessionID: SessionID,
        providerID: ProviderID,
        prompt: String,
        attachments: [ImageAttachment] = [],
        modelID: ModelID? = nil,
        effort: ReasoningEffort? = nil,
        workingDirectory: String? = nil,
        resumeToken: String? = nil
    ) {
        self.turnID = turnID
        self.sessionID = sessionID
        self.providerID = providerID
        self.prompt = prompt
        self.attachments = attachments
        self.modelID = modelID
        self.effort = effort
        self.workingDirectory = workingDirectory
        self.resumeToken = resumeToken
    }
}

/// Translates between Skynet's vocabulary and one provider CLI's wire
/// protocol: command line in, JSONL events out.
///
/// Adapters are stateless values; all per-turn state flows through the
/// arguments. They must never touch the network or the filesystem — a
/// provider that is only reachable through a relay must behave identically
/// to one running locally.
public protocol ProviderProtocolAdapter: Sendable {
    var kind: AgentProviderDescriptor.Kind { get }

    /// The argument vector (excluding the executable) for one turn.
    /// `AgentSession` prepends the provider's `defaultArguments`.
    ///
    /// - Throws: `SkynetError.attachmentUnsupported` when the turn carries
    ///   attachments this provider cannot express.
    func buildArguments(
        provider: AgentProviderDescriptor,
        turn: AgentTurnRequest,
        permissions: PermissionPolicy,
        interactivePermissions: Bool
    ) throws -> [String]

    /// Bytes to write to the process's stdin immediately after launch.
    /// `nil` when the protocol is purely argument-driven.
    func launchStdin(
        provider: AgentProviderDescriptor,
        turn: AgentTurnRequest
    ) throws -> Data?

    /// Decodes one line of the CLI's standard output into events.
    /// Malformed or unknown lines become `.unhandledEvent` — parsing never
    /// throws, so one bad frame cannot kill a live turn.
    func parseOutputLine(_ line: String, turn: AgentTurnRequest) -> [AgentEvent]

    /// Encodes a permission answer as a stdin line, or `nil` when this
    /// protocol cannot answer interactively.
    func permissionResponseStdin(_ response: PermissionResponse) -> String?
}

// MARK: - Registry

public enum ProviderProtocolAdapters {
    /// The adapter for a provider kind. New kinds are added here and only
    /// here.
    public static func adapter(
        for kind: AgentProviderDescriptor.Kind
    ) -> any ProviderProtocolAdapter {
        switch kind {
        case .codex:
            return CodexAdapter()
        case .claudeCode, .claudeCodeCompatible:
            return ClaudeCodeAdapter()
        }
    }
}
