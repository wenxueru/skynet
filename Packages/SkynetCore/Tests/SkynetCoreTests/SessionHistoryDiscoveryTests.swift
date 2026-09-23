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

    @Test func codexParserRendersImagesWithoutMarkup() throws {
        let file = try temporaryFile(contents: #"""
        {"type":"session_meta","payload":{"id":"01900000-0000-7000-8000-000000000003","cwd":"/tmp/project"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Look at this"},{"type":"input_text","text":"<image name=[Image #1] path=\"/tmp/example.png\">"},{"type":"input_image","image_url":"data:image/png;base64,AQID"},{"type":"input_text","text":"</image>"}],"internal_chat_message_metadata_passthrough":{"content_item_kinds":["user.text","user.text","user.image","user.text"]}}}
        """#)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let session = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: file))
        let message = try #require(session.messages.first)
        #expect(message.plainText == "Look at this")
        #expect(message.content.count == 2)
        if case .image(let image) = message.content[1],
           case .inline(let data, let mediaType) = image.payload {
            #expect(data == Data([1, 2, 3]))
            #expect(mediaType == "image/png")
        } else {
            Issue.record("Expected an image content block")
        }
    }

    @Test func codexParserKeepsToolCallsForGrouping() throws {
        let file = try temporaryFile(contents: """
        {"type":"session_meta","payload":{"id":"01900000-0000-7000-8000-000000000004","cwd":"/tmp/project"}}
        {"type":"response_item","payload":{"type":"custom_tool_call","call_id":"call-1","name":"exec","input":"rg TODO ."}}
        {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-1","output":"done"}}
        {"type":"response_item","payload":{"type":"function_call","call_id":"call-2","name":"Read","arguments":"{}"}}
        {"type":"response_item","payload":{"type":"function_call_output","call_id":"call-2","output":"source"}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let session = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: file))
        #expect(session.messages.count == 4)
        let groups = TranscriptGrouping.groups(session.messages)
        if case .tools(_, let steps, _) = groups.first {
            #expect(steps.map(\.call?.name) == ["exec", "Read"])
            #expect(steps.map(\.result) == ["done", "source"])
        } else { Issue.record("Expected Codex tools to be grouped") }
    }

    @Test func codexParserImportsCumulativeTokenUsageWithoutDoubleCountingCache() throws {
        let file = try temporaryFile(contents: """
        {"type":"session_meta","payload":{"id":"01900000-0000-7000-8000-000000000005"}}
        {"type":"turn_context","payload":{"model":"gpt-6-sol"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":30,"output_tokens":20}}}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":40,"output_tokens":25}}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let session = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: file))
        #expect(session.modelID == ModelID("gpt-6-sol"))
        #expect(session.totalUsage.inputTokens == 110)
        #expect(session.totalUsage.cacheReadTokens == 40)
        #expect(session.totalUsage.outputTokens == 25)
        #expect(session.totalUsage.totalTokens == 175)
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

    @Test func claudeParserKeepsBase64ImageBlocks() throws {
        let file = try temporaryFile(contents: """
        {"type":"user","sessionId":"10000000-0000-4000-8000-000000000002","message":{"content":[{"type":"text","text":"Describe this"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AQID"}}]}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let session = try #require(SessionHistoryDiscovery.parseClaudeTranscript(at: file))
        #expect(session.messages.first?.content.count == 2)
        if case .image = session.messages.first?.content.last {} else {
            Issue.record("Expected a Claude image content block")
        }
    }

    @Test func claudeParserDeduplicatesRepeatedAssistantUsage() throws {
        let file = try temporaryFile(contents: """
        {"type":"assistant","sessionId":"10000000-0000-4000-8000-000000000003","message":{"id":"msg-1","model":"claude-sonnet","content":[{"type":"text","text":"First"}],"usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":3}}}
        {"type":"assistant","sessionId":"10000000-0000-4000-8000-000000000003","message":{"id":"msg-1","model":"claude-sonnet","content":[{"type":"text","text":"Updated"}],"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":3}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let session = try #require(SessionHistoryDiscovery.parseClaudeTranscript(at: file))
        #expect(session.totalUsage.inputTokens == 10)
        #expect(session.totalUsage.cacheReadTokens == 3)
        #expect(session.totalUsage.outputTokens == 5)
        #expect(session.messages.filter { $0.usage != nil }.count == 1)
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
