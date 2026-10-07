import Foundation

public enum SessionTranscriptExport {
    public enum Format: String, Sendable {
        case json
        case markdown

        public var fileExtension: String { self == .json ? "json" : "md" }
    }

    private struct Payload: Encodable {
        let session: SessionRecord
        let messages: [Message]
        let exportedAt: Date
    }

    public static func data(
        session: SessionRecord,
        messages: [Message],
        format: Format,
        exportedAt: Date = Date(),
        loadBlob: ((BlobReference) throws -> Data)? = nil
    ) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            // Preserve milliseconds. FormatStyle truncates some binary date
            // boundaries instead of rounding, so use one formatter per export.
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(formatter.string(from: date))
            }
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(Payload(
                session: session,
                messages: messagesWithInlineImages(messages, loadBlob: loadBlob),
                exportedAt: exportedAt
            ))
        case .markdown:
            return Data(markdown(session: session, messages: messages).utf8)
        }
    }

    /// JSON exports must remain usable outside this app's content-addressed store.
    private static func messagesWithInlineImages(
        _ messages: [Message],
        loadBlob: ((BlobReference) throws -> Data)?
    ) throws -> [Message] {
        try messages.map { message in
            var exported = message
            exported.content = try message.content.map { block in
                guard case .image(var image) = block,
                      case .blob(let reference) = image.payload else { return block }
                guard let loadBlob else {
                    throw SkynetError.persistenceFailure(
                        underlying: "JSON export needs image blob \(reference.blobID), but no blob loader is available."
                    )
                }
                let bytes = try loadBlob(reference)
                guard bytes.count == reference.byteCount,
                      BlobStore.contentID(for: bytes) == reference.blobID.lowercased() else {
                    throw SkynetError.persistenceFailure(
                        underlying: "JSON export image blob \(reference.blobID) failed its size or SHA-256 check."
                    )
                }
                image.payload = .inline(data: bytes, mediaType: reference.mediaType)
                return .image(image)
            }
            return exported
        }
    }

    private static func markdown(session: SessionRecord, messages: [Message]) -> String {
        var sections = ["# \(session.title ?? "New session")"]
        for message in messages {
            var blocks: [String] = []
            for block in message.content {
                switch block {
                case .text(let text):
                    blocks.append(text)
                case .thinking(let text, _):
                    blocks.append("<details><summary>Reasoning</summary>\n\n\(text)\n\n</details>")
                case .image(let attachment):
                    blocks.append("[Image: \(attachment.fileName ?? attachment.id.uuidString)]")
                case .toolCall(let call):
                    let input = (try? JSONEncoder().encode(call.input))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
                    blocks.append("Tool: `\(call.name)`\n\n```json\n\(input)\n```")
                case .toolResult(_, let content, let isError):
                    blocks.append("Tool \(isError ? "error" : "result"):\n\n```text\n\(content)\n```")
                }
            }
            sections.append("## \(message.origin.rawValue.capitalized) · \(message.createdAt.ISO8601Format())\n\n\(blocks.joined(separator: "\n\n"))")
        }
        return sections.joined(separator: "\n\n") + "\n"
    }
}
