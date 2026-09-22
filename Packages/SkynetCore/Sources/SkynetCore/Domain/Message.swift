import Foundation

/// A tool invocation requested by the agent.
///
/// The tool itself executes *inside the agent CLI*, not in SkynetCore — the
/// core records the call, renders it, and (through the permission policy)
/// constrains what the CLI is allowed to do up front. A matching
/// `.toolResult` content block reports the outcome.
public struct ToolCall: Codable, Hashable, Sendable, Identifiable {
    public var id: ToolCallID
    public var name: String
    /// The tool arguments exactly as the provider expressed them.
    public var input: JSONValue

    public init(id: ToolCallID = ToolCallID(), name: String, input: JSONValue = .null) {
        self.id = id
        self.name = name
        self.input = input
    }
}

/// Token accounting for a turn or a session, in the provider's own units.
///
/// All fields optional: providers report different subsets and the UI must
/// tolerate gaps.
public struct TokenUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var outputTokens: Int?
    public var reasoningTokens: Int?

    public init(
        inputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }

    /// The cost-relevant total: input + cache writes + output (cache reads
    /// are steeply discounted, but still counted).
    public var totalTokens: Int? {
        let parts = [inputTokens, cacheReadTokens, cacheWriteTokens, outputTokens]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }

    /// Component-wise sum, treating `nil` as zero on either side.
    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: sum(lhs.inputTokens, rhs.inputTokens),
            cacheReadTokens: sum(lhs.cacheReadTokens, rhs.cacheReadTokens),
            cacheWriteTokens: sum(lhs.cacheWriteTokens, rhs.cacheWriteTokens),
            outputTokens: sum(lhs.outputTokens, rhs.outputTokens),
            reasoningTokens: sum(lhs.reasoningTokens, rhs.reasoningTokens)
        )
    }

    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs = lhs + rhs
    }

    private static func sum(_ a: Int?, _ b: Int?) -> Int? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (let a?, let b?): return a + b
        }
    }
}

/// One block of content inside a message.
///
/// Mirrors the Anthropic content-block model because both built-in providers
/// speak something close to it, but the vocabulary is Skynet's own.
public enum ContentBlock: Codable, Hashable, Sendable {
    /// Plain text.
    case text(String)
    /// Model reasoning. Providers that always think (or are configured to)
    /// emit this alongside `.text`.
    case thinking(text: String, signature: String?)
    /// An image attached by the user.
    case image(ImageAttachment)
    /// The agent asking to invoke a tool.
    case toolCall(ToolCall)
    /// The outcome of a tool invocation, matched by `ToolCallID`.
    case toolResult(toolCallID: ToolCallID, content: String, isError: Bool)

    public var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    public var toolCall: ToolCall? {
        if case .toolCall(let call) = self { return call }
        return nil
    }
}

/// One message in a session transcript.
///
/// `origin` (not `role`) is the domain vocabulary: the wire-level "user"
/// role is overloaded — it covers both human turns and tool results — so the
/// core keeps them distinct and lets each adapter map to its wire format.
public struct Message: Codable, Hashable, Sendable, Identifiable {
    public enum Origin: String, Codable, Sendable, CaseIterable {
        /// Typed by the human.
        case user
        /// Produced by the model.
        case agent
        /// Produced by tool execution inside the agent CLI.
        case toolResult
        /// Session bookkeeping the UI renders as a system line.
        case system
    }

    public var id: MessageID
    public var origin: Origin
    public var content: [ContentBlock]
    public var createdAt: Date
    /// The model that produced this message (agent origin only).
    public var modelID: ModelID?
    public var providerID: ProviderID?
    public var usage: TokenUsage?

    public init(
        id: MessageID = MessageID(),
        origin: Origin,
        content: [ContentBlock],
        createdAt: Date = Date(),
        modelID: ModelID? = nil,
        providerID: ProviderID? = nil,
        usage: TokenUsage? = nil
    ) {
        self.id = id
        self.origin = origin
        self.content = content
        self.createdAt = createdAt
        self.modelID = modelID
        self.providerID = providerID
        self.usage = usage
    }

    /// Concatenated text of all `.text` blocks — the one-line preview.
    public var plainText: String {
        content.compactMap(\.text).joined()
    }
}
