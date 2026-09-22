import Foundation

/// A single element of a session transcript. Modeled as an enum so the UI can
/// switch exhaustively over row kinds while each payload stays a plain value.
public enum TranscriptItem: Identifiable, Hashable, Sendable {
    case userMessage(UserMessage)
    case assistantMessage(AssistantMessage)
    case toolCall(ToolCallRecord)
    case permissionRequest(PermissionRequestRecord)
    case systemNotice(SystemNotice)

    public var id: TranscriptItemID {
        switch self {
        case .userMessage(let m): return m.id
        case .assistantMessage(let m): return m.id
        case .toolCall(let c): return c.id
        case .permissionRequest(let r): return r.id
        case .systemNotice(let n): return n.id
        }
    }

    public var timestamp: Date {
        switch self {
        case .userMessage(let m): return m.sentAt
        case .assistantMessage(let m): return m.sentAt
        case .toolCall(let c): return c.startedAt
        case .permissionRequest(let r): return r.requestedAt
        case .systemNotice(let n): return n.date
        }
    }

    /// Plain-text projection used by search.
    public var searchableText: String {
        switch self {
        case .userMessage(let m): return m.text
        case .assistantMessage(let m): return m.text
        case .toolCall(let c):
            return [c.title, c.arguments ?? "", c.output ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        case .permissionRequest(let r):
            return [r.summary, r.detail ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        case .systemNotice(let n): return n.text
        }
    }
}

/// Delivery state of an outgoing user message.
public enum MessageDeliveryState: Hashable, Sendable {
    case sending
    case delivered
    /// Held locally until the connection or the running turn frees up.
    case queued
    case failed(reason: String)
}

public struct UserMessage: Identifiable, Hashable, Sendable {
    public let id: TranscriptItemID
    public var text: String
    public var attachments: [ImageAttachment]
    public var sentAt: Date
    public var deliveryState: MessageDeliveryState

    public init(
        id: TranscriptItemID,
        text: String,
        attachments: [ImageAttachment] = [],
        sentAt: Date = Date(timeIntervalSince1970: 0),
        deliveryState: MessageDeliveryState = .delivered
    ) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.sentAt = sentAt
        self.deliveryState = deliveryState
    }
}

/// A streaming or completed assistant reply.
public struct AssistantMessage: Identifiable, Hashable, Sendable {
    public let id: TranscriptItemID
    public var text: String
    /// True while deltas are still arriving for this message.
    public var isStreaming: Bool
    public var sentAt: Date
    public var modelID: String?

    public init(
        id: TranscriptItemID,
        text: String,
        isStreaming: Bool = false,
        sentAt: Date = Date(timeIntervalSince1970: 0),
        modelID: String? = nil
    ) {
        self.id = id
        self.text = text
        self.isStreaming = isStreaming
        self.sentAt = sentAt
        self.modelID = modelID
    }
}

public enum ToolKind: String, Codable, CaseIterable, Sendable {
    case shell
    case fileEdit
    case fileRead
    case search
    case web
    case other

    public var displayName: String {
        switch self {
        case .shell: return "Shell"
        case .fileEdit: return "Edit"
        case .fileRead: return "Read"
        case .search: return "Search"
        case .web: return "Web"
        case .other: return "Tool"
        }
    }
}

public enum ToolCallState: String, Codable, Sendable {
    case running
    case succeeded
    case failed
    case canceled

    public var isFinished: Bool { self != .running }
}

/// A tool invocation by the agent: command, file edit, search, and so on.
public struct ToolCallRecord: Identifiable, Hashable, Sendable {
    public let id: TranscriptItemID
    /// Human title, e.g. "npm test" or "Edit SessionView.swift".
    public var title: String
    public var kind: ToolKind
    /// Pretty-printed arguments (JSON, command line, diff…).
    public var arguments: String?
    public var output: String?
    /// True when the relay truncated `output` for size.
    public var outputTruncated: Bool
    public var state: ToolCallState
    public var startedAt: Date
    public var finishedAt: Date?

    public init(
        id: TranscriptItemID,
        title: String,
        kind: ToolKind = .other,
        arguments: String? = nil,
        output: String? = nil,
        outputTruncated: Bool = false,
        state: ToolCallState = .running,
        startedAt: Date = Date(timeIntervalSince1970: 0),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.arguments = arguments
        self.output = output
        self.outputTruncated = outputTruncated
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}

/// A permission request surfaced inline in the transcript.
public struct PermissionRequestRecord: Identifiable, Hashable, Sendable {
    public let id: TranscriptItemID
    public var summary: String
    public var detail: String?
    public var scope: PermissionScope
    public var requestedAt: Date
    /// `nil` while the request is still pending a user answer.
    public var decision: PermissionDecision?

    public init(
        id: TranscriptItemID,
        summary: String,
        detail: String? = nil,
        scope: PermissionScope = .other,
        requestedAt: Date = Date(timeIntervalSince1970: 0),
        decision: PermissionDecision? = nil
    ) {
        self.id = id
        self.summary = summary
        self.detail = detail
        self.scope = scope
        self.requestedAt = requestedAt
        self.decision = decision
    }

    public var isPending: Bool { decision == nil }
}

public enum NoticeSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}

public struct SystemNotice: Identifiable, Hashable, Sendable {
    public let id: TranscriptItemID
    public var text: String
    public var severity: NoticeSeverity
    public var date: Date

    public init(
        id: TranscriptItemID,
        text: String,
        severity: NoticeSeverity = .info,
        date: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.id = id
        self.text = text
        self.severity = severity
        self.date = date
    }
}

/// Policy for collapsing long messages behind a "Show more" affordance.
///
/// Measured in characters and newlines rather than rendered lines so the
/// decision is deterministic and testable without layout.
public struct LongMessagePolicy: Sendable {
    public var characterLimit: Int
    public var lineLimit: Int

    public init(characterLimit: Int = 700, lineLimit: Int = 16) {
        self.characterLimit = characterLimit
        self.lineLimit = lineLimit
    }

    public static let `default` = LongMessagePolicy()

    /// True when `text` exceeds the limits and should start collapsed.
    public func shouldCollapse(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if text.count >= characterLimit { return true }
        let newlines = text.reduce(into: 0) { count, char in
            if char == "\n" { count += 1 }
        }
        return newlines + 1 >= lineLimit
    }

    /// The prefix shown while collapsed. Always breaks on a character that
    /// keeps whitespace intact so markdown is not split mid-token more than
    /// unavoidable.
    public func preview(of text: String) -> String {
        guard shouldCollapse(text) else { return text }
        let keep = text.count > characterLimit ? characterLimit : text.count
        let index = text.index(text.startIndex, offsetBy: keep)
        return String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
