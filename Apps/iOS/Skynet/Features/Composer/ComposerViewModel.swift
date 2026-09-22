import Foundation

/// Presentation logic for the bottom composer: draft text, attachments, and
/// the send-vs-queue decision. All session truth stays behind
/// `ComposerStateProviding`; this model only shapes what the composer shows.
@MainActor
@Observable
public final class ComposerViewModel {
    /// What the primary button should do right now.
    public enum SendAction: Equatable {
        /// Link is up and the turn is free — send immediately.
        case send
        /// Offline or the turn is busy — offer explicit queueing.
        case queue
        /// Nothing to send.
        case disabled
    }

    public static let maxAttachments = 4

    public var draftText = ""
    public var attachments: [ImageAttachment] = []
    public var isPhotoPickerPresented = false
    public var isCameraPresented = false
    /// Composer input focus, driven by the view but owned here so previews
    /// and UI tests can script it.
    public var isFocused = false

    public let state: any ComposerStateProviding

    public init(state: any ComposerStateProviding) {
        self.state = state
    }

    // MARK: - Draft state

    public var isDraftEmpty: Bool {
        currentPayload.isEffectivelyEmpty
    }

    public var currentPayload: PromptPayload {
        PromptPayload(text: draftText, attachments: attachments)
    }

    public var canAttachMore: Bool {
        attachments.count < Self.maxAttachments
    }

    public var attachmentTotalBytes: Int {
        attachments.reduce(0) { $0 + $1.byteCount }
    }

    /// The action the send button should perform for the current draft.
    public var sendAction: SendAction {
        guard !isDraftEmpty else { return .disabled }
        guard state.currentConnectionState.isConnected else { return .queue }
        guard state.currentTurnState.acceptsNewPrompt else { return .queue }
        return .send
    }

    /// Icon + label for the primary button, matching `sendAction`.
    public var sendButtonImage: String {
        switch sendAction {
        case .send: return "arrow.up.circle.fill"
        case .queue: return "arrow.down.circle.fill"
        case .disabled: return "arrow.up.circle.fill"
        }
    }

    public var sendButtonLabel: String {
        switch sendAction {
        case .send: return "Send"
        case .queue: return "Add to queue"
        case .disabled: return "Send"
        }
    }

    // MARK: - Actions

    /// Performs the primary action if possible; clears the draft only when
    /// something was actually dispatched.
    public func performPrimaryAction() {
        let payload = currentPayload
        switch sendAction {
        case .send:
            state.composerDidRequestSend(payload)
            clearDraft()
        case .queue:
            state.composerDidRequestQueue(payload)
            clearDraft()
        case .disabled:
            break
        }
    }

    public func clearDraft() {
        draftText = ""
        attachments = []
    }

    // MARK: - Attachments

    /// Adds an attachment unless the cap is reached.
    @discardableResult
    public func attach(_ attachment: ImageAttachment) -> Bool {
        guard canAttachMore else { return false }
        attachments.append(attachment)
        return true
    }

    public func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: - Configuration passthrough

    public var currentConfiguration: AgentConfiguration {
        state.currentConfiguration
    }

    public var queuedPromptCount: Int {
        state.queuedPromptCount
    }

    /// Applies a mutation to the session configuration.
    public func updateConfiguration(_ mutate: (inout AgentConfiguration) -> Void) {
        var configuration = state.currentConfiguration
        mutate(&configuration)
        state.composerDidChangeConfiguration(configuration)
    }
}
