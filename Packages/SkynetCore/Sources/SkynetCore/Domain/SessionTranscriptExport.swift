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
        exportedAt: Date = Date()
    ) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(Payload(
                session: session, messages: messages, exportedAt: exportedAt
            ))
        case .markdown:
            return Data(markdown(session: session, messages: messages).utf8)
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
