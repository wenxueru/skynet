import Foundation

/// A prompt ready to be handed to the relay.
public struct PromptPayload: Equatable, Sendable {
    public var text: String
    public var attachments: [ImageAttachment]

    public init(text: String, attachments: [ImageAttachment] = []) {
        self.text = text
        self.attachments = attachments
    }

    public var isEffectivelyEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    /// Equality ignores attachment byte payloads; identity is enough.
    public static func == (lhs: PromptPayload, rhs: PromptPayload) -> Bool {
        lhs.text == rhs.text && lhs.attachments.map(\.id) == rhs.attachments.map(\.id)
    }
}

/// A prompt held back until it can be sent, plus why it was held.
public struct QueuedPrompt: Identifiable, Equatable, Sendable {
    public enum HoldReason: Equatable, Sendable {
        /// The relay link was down when the prompt was composed.
        case offline
        /// Another turn was already running.
        case turnBusy
        /// The user explicitly queued it for later.
        case userRequested
    }

    public let id: UUID
    public var payload: PromptPayload
    public var queuedAt: Date
    public var reason: HoldReason

    public init(
        id: UUID = UUID(),
        payload: PromptPayload,
        queuedAt: Date = Date(timeIntervalSince1970: 0),
        reason: HoldReason
    ) {
        self.id = id
        self.payload = payload
        self.queuedAt = queuedAt
        self.reason = reason
    }
}
