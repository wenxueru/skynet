import Foundation
import SkynetCore

/// Session-scoped draft/queue JSON and attachment blobs. Does not select a
/// session, dispatch a turn, or register a scheduled message.
struct SessionComposerStorage {
    struct QueuedPrompt: Codable, Identifiable {
        var id = UUID()
        var text: String
        var attachments: [ImageAttachment]
        var createdAt = Date()
        var scheduledAt: Date? = nil
        /// A persisted dispatch marker prevents an uncertain send from being replayed.
        var dispatchStartedAt: Date? = nil
    }

    struct ComposerDraft: Codable {
        var text: String
        var attachments: [ImageAttachment]
    }

    let rootURL: URL?
    let blobs: JSONDiskStore?

    func storedAttachments(_ attachments: [ImageAttachment]) throws -> [ImageAttachment] {
        try attachments.map { attachment in
            var stored = attachment
            if case .inline(let data, let mediaType) = stored.payload {
                guard let blobs else { throw CocoaError(.fileNoSuchFile) }
                stored.payload = .blob(try blobs.storeBlob(
                    data, mediaType: mediaType, fileName: stored.fileName
                ))
            }
            return stored
        }
    }

    func saveDraft(_ text: String, attachments: [ImageAttachment], for sessionID: SessionID) throws {
        guard let url = fileURL(in: "composer-drafts", for: sessionID) else { return }
        try createParent(of: url)
        let draft = ComposerDraft(text: text, attachments: try storedAttachments(attachments))
        try JSONEncoder().encode(draft).write(to: url, options: .atomic)
    }

    func loadDraft(for sessionID: SessionID) -> ComposerDraft? {
        read(ComposerDraft.self, in: "composer-drafts", for: sessionID)
    }

    func queueEntries(for sessionID: SessionID) -> [QueuedPrompt] {
        let entries = read([QueuedPrompt].self, in: "message-queues", for: sessionID) ?? []
        return Array(entries.prefix(100))
    }

    func persistQueue(_ entries: [QueuedPrompt], for sessionID: SessionID) throws {
        guard let url = fileURL(in: "message-queues", for: sessionID) else { throw CocoaError(.fileNoSuchFile) }
        try createParent(of: url)
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }

    func removeSessionFiles(for sessionID: SessionID) {
        // Legacy scratchlists are cleanup-only; never revived as a feature.
        for directory in ["scratchlists", "message-queues", "composer-drafts"] {
            if let url = fileURL(in: directory, for: sessionID) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func fileURL(in directory: String, for sessionID: SessionID) -> URL? {
        rootURL?.appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("\(sessionID.value.uuidString).json")
    }

    private func createParent(of url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func read<Value: Decodable>(_ type: Value.Type, in directory: String, for sessionID: SessionID) -> Value? {
        guard let url = fileURL(in: directory, for: sessionID), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
