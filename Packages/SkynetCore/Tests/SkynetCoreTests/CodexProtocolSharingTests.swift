import Foundation
@testable import SkynetCore
import Testing

@Suite("Shared Codex protocol")
struct CodexProtocolSharingTests {
    @Test func execAndAppServerShareDisjointUsageNormalization() throws {
        let turn = AgentTurnRequest(sessionID: SessionID(), providerID: .codex, prompt: "fixture")
        let frame: JSONValue = ["id": "fixture", "msg": [
            "type": "token_count", "input_tokens": 100, "cached_input_tokens": 20,
            "cache_write_input_tokens": 5, "output_tokens": 12, "reasoning_output_tokens": 4,
        ]]
        let exec = try #require(CodexAdapter().parseOutputLine(
            String(decoding: JSONEncoder().encode(frame), as: UTF8.self), turn: turn
        ).compactMap { event -> TokenUsage? in
            if case .usageReported(let usage) = event { return usage }
            return nil
        }.first)
        let snapshot: JSONValue = ["inputTokens": 100, "cachedInputTokens": 20,
            "cacheWriteInputTokens": 5, "outputTokens": 12, "reasoningOutputTokens": 4]
        var tracker = CodexAppServerBridge.UsageTracker()
        let appServer = tracker.observe(["params": ["tokenUsage": [
            "total": snapshot, "last": snapshot,
        ]]])
        #expect(appServer == exec)
        #expect(exec.inputTokens == 75)
        #expect(exec.cacheReadTokens == 20 && exec.cacheWriteTokens == 5)
        #expect(exec.outputTokens == 12 && exec.reasoningTokens == 4)
    }

    @Test func sharedJSONLineEncodingPreservesTextAndStructuredToolOutput() throws {
        let frame: JSONValue = ["id": 7, "method": "fixture", "params": ["text": "问题\nnext"]]
        let encoded = try CodexAppServerBridge.encode(frame)
        #expect(encoded.last == 0x0A)
        #expect(encoded.filter { $0 == 0x0A }.count == 1)
        #expect(try JSONDecoder().decode(JSONValue.self, from: encoded) == frame)
        #expect(CodexEventParsing.renderToolOutput(nil).isEmpty)
        #expect(CodexEventParsing.renderToolOutput(.null).isEmpty)
        #expect(CodexEventParsing.renderToolOutput(.string("plain\ntext")) == "plain\ntext")
        let structured = CodexEventParsing.renderToolOutput(frame)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(structured.utf8)) == frame)
    }
}
