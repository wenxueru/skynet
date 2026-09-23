import Foundation
import SkynetCore
import Testing

@Suite("Session transcript export")
struct SessionTranscriptExportTests {
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
