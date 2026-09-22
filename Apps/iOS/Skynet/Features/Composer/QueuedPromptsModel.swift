import Foundation

/// Holds prompts that are waiting to be sent, and flushes them in FIFO order
/// when conditions allow. The transcript itself stays relay-driven; queued
/// prompts surface through the composer's queue affordances.
@MainActor
@Observable
public final class QueuedPromptsModel {
    public private(set) var prompts: [QueuedPrompt] = []
    public private(set) var isFlushing = false
    /// Set when a flush attempt failed; cleared on the next successful send.
    public private(set) var lastFlushError: String?

    public init() {}

    public var count: Int { prompts.count }
    public var isEmpty: Bool { prompts.isEmpty }
    public var nextPrompt: QueuedPrompt? { prompts.first }

    /// Enqueues a prompt for later delivery and returns the queue entry.
    @discardableResult
    public func enqueue(
        _ payload: PromptPayload,
        reason: QueuedPrompt.HoldReason
    ) -> QueuedPrompt {
        let entry = QueuedPrompt(payload: payload, reason: reason)
        prompts.append(entry)
        return entry
    }

    /// Removes a queued prompt without sending it.
    public func remove(_ id: UUID) {
        prompts.removeAll { $0.id == id }
    }

    public func removeAll() {
        prompts.removeAll()
    }

    /// Sends as many queued prompts as `shouldSend` allows, strictly in FIFO
    /// order. Stops at the first failure and keeps the remainder (including
    /// the failed entry) queued for the next trigger.
    public func flush(
        shouldSend: @MainActor () -> Bool,
        send: @MainActor (_ prompt: QueuedPrompt) async throws -> Void
    ) async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        while let next = prompts.first, shouldSend() {
            do {
                try await send(next)
                // Remove exactly the entry that was sent; the list may have
                // changed while the send was in flight.
                prompts.removeAll { $0.id == next.id }
                lastFlushError = nil
            } catch {
                lastFlushError = error.localizedDescription
                Log.composer.error("Queued prompt send failed: \(error.localizedDescription)")
                break
            }
        }
    }

    /// Pops a specific prompt out of the queue (used by "send now").
    public func take(_ id: UUID) -> QueuedPrompt? {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else { return nil }
        return prompts.remove(at: index)
    }
}
