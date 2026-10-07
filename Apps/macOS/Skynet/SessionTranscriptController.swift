import Foundation
import Observation
import SkynetCore

/// Cache-first history synchronization. Owns visible messages, byte cursors and
/// request generations; record metadata is supplied by the application shell.
@MainActor
@Observable
final class SessionTranscriptController {
    struct Hooks {
        var record: (SessionID) -> SessionRecord?
        var save: (SessionRecord) -> Void
        var reportError: (String?) -> Void
    }

    private struct TranscriptLoadResult: Sendable {
        let messages: [Message]
        let olderCursor: Int64?
        let errorMessage: String?
    }

    private enum TranscriptCursor: Hashable {
        case provider(Int64)
        case cache(Int64)
    }

    var selectedSessionID: SessionID?
    var messages: [Message] = [] {
        didSet { groups = TranscriptGrouping.groups(messages) }
    }
    private(set) var groups: [TranscriptGroup] = []
    private(set) var isLoadingTranscript = false
    var isLoadingOlderTranscript: Bool {
        selectedSessionID != nil && loadingOlderTranscriptSessionID == selectedSessionID
    }
    var canLoadOlderTranscript: Bool {
        selectedSessionID.flatMap { transcriptCursors[$0] } != nil
    }

    private let store: JSONDiskStore?
    private var transcriptTask: Task<Void, Never>?
    private var loadingOlderTranscriptSessionID: SessionID?
    private var transcriptCursors: [SessionID: TranscriptCursor] = [:]
    private var transcriptCacheCursors: [SessionID: Int64] = [:]
    private var transcriptLoadToken = UUID()

    init(store: JSONDiskStore?) { self.store = store }

    func clear() {
        transcriptLoadToken = UUID()
        transcriptTask?.cancel()
        transcriptTask = nil
        messages = []
        isLoadingTranscript = false
    }

    func load(
        for sessionID: SessionID,
        record transcriptRecord: SessionRecord?,
        preservePagination: Bool,
        hooks: Hooks
    ) {
        let loadToken = UUID()
        transcriptLoadToken = loadToken
        transcriptTask?.cancel()
        // A refresh can interrupt the initial load before it installs a cursor.
        // Preserve an existing cursor, not an uninitialized empty pagination state.
        let preserveExistingPagination = preservePagination && transcriptCursors[sessionID] != nil
        if !preserveExistingPagination {
            transcriptCursors[sessionID] = nil
            transcriptCacheCursors[sessionID] = nil
        }
        guard let store else {
            hooks.reportError(SkynetError.persistenceFailure(
                underlying: "The application data directory is unavailable."
            ).localizedDescription)
            isLoadingTranscript = false
            return
        }
        isLoadingTranscript = messages.isEmpty
        transcriptTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    let page = try store.loadMessagesPage(for: sessionID)
                    return TranscriptLoadResult(
                        messages: page.messages,
                        olderCursor: page.olderCursor,
                        errorMessage: nil
                    )
                } catch {
                    return TranscriptLoadResult(
                        messages: [],
                        olderCursor: nil,
                        errorMessage: error.localizedDescription
                    )
                }
            }.value
            guard let self,
                  !Task.isCancelled,
                  isCurrentTranscriptLoad(loadToken, for: sessionID) else { return }
            messages = TranscriptMessageMerger.merge(result.messages, messages)
            hooks.reportError(result.errorMessage)
            if !preserveExistingPagination {
                transcriptCacheCursors[sessionID] = result.olderCursor
                transcriptCursors[sessionID] = result.olderCursor.map(TranscriptCursor.cache)
            }
            isLoadingTranscript = false
            if let transcriptRecord {
                do {
                    if let page = try await SessionTranscriptDiscovery.transcriptPage(for: transcriptRecord) {
                        guard !Task.isCancelled,
                              isCurrentTranscriptLoad(loadToken, for: sessionID) else { return }
                        let imported = page.session
                        let mergedMessages = TranscriptMessageMerger.merge(
                            imported.messages, messages
                        )
                        let visibleMessages = try await Self.persistableMessagesInBackground(
                            mergedMessages, store: store
                        )
                        guard !Task.isCancelled,
                              isCurrentTranscriptLoad(loadToken, for: sessionID) else { return }
                        let cacheUpdate = try await Self.cacheProviderMessages(
                            visibleMessages, for: sessionID, store: store
                        )
                        guard !Task.isCancelled,
                              isCurrentTranscriptLoad(loadToken, for: sessionID) else { return }
                        messages = TranscriptMessageMerger.merge(visibleMessages, messages)
                        if cacheUpdate.didRewrite {
                            transcriptCacheCursors[sessionID] = cacheUpdate.olderCursor
                            if case .cache = transcriptCursors[sessionID] {
                                transcriptCursors[sessionID] = cacheUpdate.olderCursor.map(TranscriptCursor.cache)
                            }
                        }
                        if !preserveExistingPagination {
                            transcriptCursors[sessionID] = page.olderCursor.map(TranscriptCursor.provider)
                                ?? transcriptCacheCursors[sessionID].map(TranscriptCursor.cache)
                        }
                        var updated = hooks.record(sessionID) ?? transcriptRecord
                        updated.messageCount = max(0, updated.messageCount + cacheUpdate.countDelta)
                        updated.updatedAt = max(updated.updatedAt, imported.updatedAt)
                        hooks.save(updated)
                    }
                } catch {
                    guard !Task.isCancelled,
                          isCurrentTranscriptLoad(loadToken, for: sessionID) else { return }
                    hooks.reportError("Session history could not be fully loaded: \(error.localizedDescription)")
                }
            }
            guard !Task.isCancelled,
                  isCurrentTranscriptLoad(loadToken, for: sessionID) else { return }
            transcriptTask = nil
        }
    }

    private func isCurrentTranscriptLoad(_ token: UUID, for sessionID: SessionID) -> Bool {
        selectedSessionID == sessionID && transcriptLoadToken == token
    }

    func loadOlderTranscript(hooks: Hooks) async {
        guard let sessionID = selectedSessionID,
              loadingOlderTranscriptSessionID != sessionID,
              transcriptCursors[sessionID] != nil,
              let store else { return }
        let loadToken = transcriptLoadToken
        loadingOlderTranscriptSessionID = sessionID
        defer {
            if loadingOlderTranscriptSessionID == sessionID {
                loadingOlderTranscriptSessionID = nil
            }
        }

        do {
            var visited: Set<TranscriptCursor> = []
            // Provider pages may overlap the cache or contain only metadata.
            // Skip those within a bounded request, never scan the whole history.
            for _ in 0..<8 {
                try Task.checkCancellation()
                guard isCurrentTranscriptLoad(loadToken, for: sessionID),
                      let cursor = transcriptCacheCursors[sessionID].map(TranscriptCursor.cache)
                        ?? transcriptCursors[sessionID] else { return }
                // Older cached rows are immediately available. Keep the provider
                // cursor separately so checking it later still fills cache holes.
                guard visited.insert(cursor).inserted else {
                    throw SkynetError.executionFailed(reason: "Transcript pagination did not advance.")
                }
                if try await loadOlderTranscriptPage(
                    cursor, for: sessionID, loadToken: loadToken, store: store, hooks: hooks
                ) { return }
            }
        } catch {
            if isCurrentTranscriptLoad(loadToken, for: sessionID) {
                hooks.reportError("Could not load older session messages: \(error.localizedDescription)")
            }
        }
    }

    /// Returns true once a page contributes previously unseen visible messages.
    private func loadOlderTranscriptPage(
        _ cursor: TranscriptCursor, for sessionID: SessionID,
        loadToken: UUID, store: JSONDiskStore, hooks: Hooks
    ) async throws -> Bool {
        switch cursor {
        case .provider(let sourceCursor):
            guard let record = hooks.record(sessionID) else {
                transcriptCursors[sessionID] = transcriptCacheCursors[sessionID]
                    .map(TranscriptCursor.cache)
                return false
            }
            let page = try await SessionTranscriptDiscovery.transcriptPage(
                for: record, before: sourceCursor
            )
            guard isCurrentTranscriptLoad(loadToken, for: sessionID) else { return false }
            guard let page else {
                transcriptCursors[sessionID] = transcriptCacheCursors[sessionID]
                    .map(TranscriptCursor.cache)
                return false
            }
            let hasNewMessages = !TranscriptMessageMerger.messagesNotIn(
                page.session.messages, comparedTo: messages
            ).isEmpty
            let mergedMessages = TranscriptMessageMerger.merge(page.session.messages, messages)
            let visibleMessages = try await Self.persistableMessagesInBackground(
                mergedMessages, store: store
            )
            guard isCurrentTranscriptLoad(loadToken, for: sessionID) else { return false }
            let cacheUpdate = try await Self.cacheProviderMessages(
                visibleMessages, for: sessionID, store: store
            )
            guard isCurrentTranscriptLoad(loadToken, for: sessionID) else { return false }
            messages = TranscriptMessageMerger.merge(visibleMessages, messages)
            if cacheUpdate.didRewrite {
                // Rewriting chronological history invalidates old byte offsets.
                transcriptCacheCursors[sessionID] = cacheUpdate.olderCursor
                if var updated = hooks.record(sessionID) {
                    updated.messageCount = max(0, updated.messageCount + cacheUpdate.countDelta)
                    hooks.save(updated)
                }
            }
            transcriptCursors[sessionID] = page.olderCursor.map(TranscriptCursor.provider)
                ?? transcriptCacheCursors[sessionID].map(TranscriptCursor.cache)
            return hasNewMessages

        case .cache(let cacheCursor):
            let page = try await Task.detached(priority: .userInitiated) {
                try store.loadMessagesPage(for: sessionID, before: cacheCursor)
            }.value
            guard isCurrentTranscriptLoad(loadToken, for: sessionID) else { return false }
            let hasNewMessages = !TranscriptMessageMerger.messagesNotIn(
                page.messages, comparedTo: messages
            ).isEmpty
            messages = TranscriptMessageMerger.merge(page.messages, messages)
            transcriptCacheCursors[sessionID] = page.olderCursor
            if let currentCursor = transcriptCursors[sessionID],
               case .provider = currentCursor {
                return hasNewMessages
            }
            transcriptCursors[sessionID] = page.olderCursor.map(TranscriptCursor.cache)
            return hasNewMessages
        }
    }

    nonisolated static func persistableMessages(
        _ messages: [Message],
        store: JSONDiskStore
    ) throws -> [Message] {
        try messages.map { message in
            var stored = message
            stored.content = try message.content.map { block in
                guard case .image(var attachment) = block,
                      case .inline(let data, let mediaType) = attachment.payload else { return block }
                attachment.payload = .blob(try store.storeBlob(
                    data, mediaType: mediaType, fileName: attachment.fileName
                ))
                return .image(attachment)
            }
            return stored
        }
    }

    nonisolated private static func persistableMessagesInBackground(
        _ messages: [Message],
        store: JSONDiskStore
    ) async throws -> [Message] {
        try await Task.detached(priority: .userInitiated) {
            try persistableMessages(messages, store: store)
        }.value
    }

    nonisolated private static func cacheProviderMessages(
        _ messages: [Message], for sessionID: SessionID, store: JSONDiskStore
    ) async throws -> (countDelta: Int, didRewrite: Bool, olderCursor: Int64?) {
        try await Task.detached(priority: .utility) {
            let result = try store.mergeMessagesResult(messages, for: sessionID)
            let cursor = result.didRewrite ? try store.loadMessagesPage(for: sessionID).olderCursor : nil
            return (result.countDelta, result.didRewrite, cursor)
        }.value
    }

}
