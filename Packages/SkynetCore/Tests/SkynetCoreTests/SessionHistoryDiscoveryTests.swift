import Foundation
import SkynetCore
import Testing

@Suite("Session history discovery")
struct SessionHistoryDiscoveryTests {
    @Test func sshConfigReturnsOnlyLiteralHostsInOrder() {
        let config = """
        Host *
          ServerAliveInterval 30
        Host build-a build-b *.internal !blocked
          User runner
        host build-a
        """

        #expect(SSHConfigParser.hosts(in: config).map(\.alias) == ["build-a", "build-b"])
    }

    @Test func codexParserKeepsUserTextAndDropsInjectedContext() throws {
        let file = try temporaryFile(contents: """
        {"timestamp":"2026-09-22T01:00:00.000Z","type":"session_meta","payload":{"id":"01900000-0000-7000-8000-000000000001","timestamp":"2026-09-22T01:00:00.000Z","cwd":"/tmp/project","source":"cli"}}
        {"timestamp":"2026-09-22T01:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>hidden</environment_context>"}],"internal_chat_message_metadata_passthrough":{"content_item_kinds":["environments.environment_context"]}}}
        {"timestamp":"2026-09-22T01:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the tests"}],"internal_chat_message_metadata_passthrough":{"content_item_kinds":["user.text"]}}}
        {"timestamp":"2026-09-22T01:00:03.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let session = try #require(
            SessionHistoryDiscovery.parseCodexTranscript(at: file, indexedTitle: "Repair tests")
        )
        #expect(session.title == "Repair tests")
        #expect(session.workingDirectory == "/tmp/project")
        #expect(session.messages.map(\.plainText) == ["Fix the tests", "Done"])
    }

    @Test func codexParserSkipsSubagentRollouts() throws {
        let file = try temporaryFile(contents: """
        {"timestamp":"2026-09-22T01:00:00.000Z","type":"session_meta","payload":{"id":"01900000-0000-7000-8000-000000000002","cwd":"/tmp/project","source":{"subagent":{"other":"worker"}}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        #expect(SessionHistoryDiscovery.parseCodexTranscript(at: file) == nil)
    }

    @Test func claudeParserUsesAITitleAndTextMessages() throws {
        let file = try temporaryFile(contents: """
        {"type":"ai-title","sessionId":"10000000-0000-4000-8000-000000000001","aiTitle":"Refactor storage"}
        {"type":"user","sessionId":"10000000-0000-4000-8000-000000000001","cwd":"/tmp/project","timestamp":"2026-09-22T02:00:00.000Z","message":{"role":"user","content":"<local-command-caveat>hidden</local-command-caveat><command-name>/model</command-name>Please refactor storage<system-reminder>hidden</system-reminder>"}}
        {"type":"assistant","sessionId":"10000000-0000-4000-8000-000000000001","cwd":"/tmp/project","timestamp":"2026-09-22T02:00:01.000Z","message":{"role":"assistant","model":"claude-sonnet","content":[{"type":"text","text":"Finished"}]}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let session = try #require(SessionHistoryDiscovery.parseClaudeTranscript(at: file))
        #expect(session.title == "Refactor storage")
        #expect(session.modelID == ModelID("claude-sonnet"))
        #expect(session.messages.map(\.plainText) == ["Please refactor storage", "Finished"])
    }

    private func temporaryFile(contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        try Data(contents.utf8).write(to: file)
        return file
    }
}
