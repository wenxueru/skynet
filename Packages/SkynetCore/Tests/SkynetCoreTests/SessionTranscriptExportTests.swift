import Foundation
import SkynetCore
import Testing

@Suite("Session transcript export")
struct SessionTranscriptExportTests {
    private struct ExportedPayload: Decodable {
        let messages: [Message]
    }

    @Test func jsonRetainsMillisecondsForRapidMessagesAndSessionDates() throws {
        let start = Date(timeIntervalSince1970: 1_791_040_000.123)
        var session = SessionRecord(providerID: .codex)
        session.createdAt = start
        session.updatedAt = start.addingTimeInterval(0.456)
        let first = Message(origin: .user, content: [.text("first")], createdAt: start)
        let second = Message(origin: .user, content: [.text("second")], createdAt: start.addingTimeInterval(0.010))
        let exportedAt = start.addingTimeInterval(0.789)
        let data = try SessionTranscriptExport.data(
            session: session, messages: [first, second], format: .json, exportedAt: exportedAt
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metadata = try #require(json["session"] as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (raw, expected) in [
            (metadata["createdAt"], start), (metadata["updatedAt"], session.updatedAt),
            (messages[0]["createdAt"], first.createdAt), (messages[1]["createdAt"], second.createdAt),
            (json["exportedAt"], exportedAt),
        ] {
            let text = try #require(raw as? String)
            let restored = try #require(formatter.date(from: text))
            #expect(abs(restored.timeIntervalSince(expected)) < 0.001)
        }
        #expect(messages[0]["createdAt"] as? String != messages[1]["createdAt"] as? String)
    }

    @Test func jsonRoundsObservedBinaryDateBoundaryToNearestMillisecond() throws {
        let date = Date(timeIntervalSinceReferenceDate: 812_286_482.635)
        var session = SessionRecord(providerID: .codex)
        session.createdAt = date
        session.updatedAt = date
        let message = Message(origin: .user, content: [.text("boundary")], createdAt: date)
        let data = try SessionTranscriptExport.data(
            session: session, messages: [message], format: .json, exportedAt: date
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metadata = try #require(json["session"] as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        for value in [metadata["createdAt"], metadata["updatedAt"], messages[0]["createdAt"], json["exportedAt"]] {
            #expect(value as? String == "2026-09-28T11:08:02.635Z")
        }
    }

    @Test func jsonIncludesPersistedImageBytes() throws {
        let directory = try TempDirectory()
        let store = try JSONDiskStore(rootURL: directory.url)
        let bytes = Data([0, 1, 2, 255])
        let reference = try store.storeBlob(bytes, mediaType: "image/png", fileName: "shot.png")
        let attachment = ImageAttachment(
            payload: .blob(reference), fileName: "shot.png", pixelWidth: 2, pixelHeight: 3
        )
        let message = Message(origin: .user, content: [.text("Photo"), .image(attachment)])
        let session = SessionRecord(providerID: .codex)
        try store.appendMessage(message, to: session.id)
        let data = try SessionTranscriptExport.data(
            session: session, messages: store.loadMessages(for: session.id), format: .json,
            loadBlob: { try store.loadBlob($0) }
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return try Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        let exported = try decoder.decode(ExportedPayload.self, from: data)
        let restored = try #require(exported.messages.first)
        #expect(restored.id == message.id)
        guard case .image(let image) = restored.content[1],
              case .inline(let actualBytes, let mediaType) = image.payload else {
            Issue.record("Exported image must not depend on the local blob store")
            return
        }
        #expect(actualBytes == bytes)
        #expect(mediaType == "image/png")
        #expect(image.id == attachment.id)
        #expect(image.fileName == "shot.png")
        #expect(image.pixelWidth == 2)
        #expect(image.pixelHeight == 3)
        #expect(try store.loadMessages(for: session.id) == [message])
    }

    @Test func jsonRejectsMissingOrCorruptImageBytes() throws {
        let directory = try TempDirectory()
        let store = try JSONDiskStore(rootURL: directory.url)
        let reference = try store.storeBlob(Data([1, 2]), mediaType: "image/png", fileName: nil)
        let message = Message(origin: .user, content: [.image(ImageAttachment(payload: .blob(reference)))])
        let session = SessionRecord(providerID: .codex)
        #expect(throws: SkynetError.self) {
            try SessionTranscriptExport.data(session: session, messages: [message], format: .json)
        }
        #expect(throws: SkynetError.self) {
            try SessionTranscriptExport.data(
                session: session, messages: [message], format: .json,
                loadBlob: { _ in throw SkynetError.notFound(what: "Blob", id: reference.blobID) }
            )
        }
        // Both truncated and same-length corrupted data must fail, not silently export.
        for invalid in [Data([1]), Data([3, 4])] {
            #expect(throws: SkynetError.self) {
                try SessionTranscriptExport.data(
                    session: session, messages: [message], format: .json,
                    loadBlob: { _ in invalid }
                )
            }
        }
    }

    @Test func inlineJSONAndMarkdownDoNotReadBlobs() throws {
        let session = SessionRecord(providerID: .codex)
        let image = ImageAttachment(data: Data([1, 2]), mediaType: "image/png", fileName: "inline.png")
        let message = Message(origin: .user, content: [.image(image)])
        for format in [SessionTranscriptExport.Format.json, .markdown] {
            let data = try SessionTranscriptExport.data(
                session: session, messages: [message], format: format,
                loadBlob: { _ in
                    Issue.record("Inline JSON and Markdown must not read the blob store")
                    throw SkynetError.notFound(what: "Unexpected blob", id: "")
                }
            )
            #expect(!data.isEmpty)
        }
        let reference = BlobReference(blobID: "absent", byteCount: 2, mediaType: "image/png")
        let markdown = try SessionTranscriptExport.data(
            session: session,
            messages: [Message(origin: .user, content: [.image(ImageAttachment(payload: .blob(reference), fileName: "photo.png"))])],
            format: .markdown
        )
        #expect(String(decoding: markdown, as: UTF8.self).contains("[Image: photo.png]"))
    }

    @Test func jsonContainsSessionAndFullTranscript() throws {
        let session = SessionRecord(providerID: .codex, title: "Example")
        let message = Message(origin: .user, content: [.text("Hello")])
        let data = try SessionTranscriptExport.data(
            session: session, messages: [message], format: .json
        )
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((json?["messages"] as? [[String: Any]])?.count == 1)
        #expect((json?["session"] as? [String: Any])?["title"] as? String == "Example")
    }

    @Test func markdownPreservesToolDetailsAndImages() throws {
        let session = SessionRecord(providerID: .claudeCode, title: "Example")
        let call = ToolCall(id: ToolCallID("call-1"), name: "Bash", input: ["command": "pwd"])
        let message = Message(origin: .agent, content: [
            .toolCall(call),
            .toolResult(toolCallID: call.id, content: "/tmp", isError: false),
            .image(ImageAttachment(data: Data([1]), mediaType: "image/png", fileName: "shot.png")),
        ])
        let data = try SessionTranscriptExport.data(
            session: session, messages: [message], format: .markdown
        )
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("# Example"))
        #expect(text.contains("Tool: `Bash`"))
        #expect(text.contains("/tmp"))
        #expect(text.contains("[Image: shot.png]"))
    }

    @Test func legacySessionStillDecodesWithoutPinOrUnreadFields() throws {
        let session = SessionRecord(providerID: .codex)
        var raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        raw.removeValue(forKey: "pinMode")
        raw.removeValue(forKey: "markedUnreadAt")
        let decoded = try JSONDecoder().decode(
            SessionRecord.self, from: JSONSerialization.data(withJSONObject: raw)
        )
        #expect(decoded.pinMode == nil)
        #expect(decoded.markedUnreadAt == nil)
    }
}
