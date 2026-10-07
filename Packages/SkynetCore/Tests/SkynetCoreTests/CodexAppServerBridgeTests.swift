import Foundation
@testable import SkynetCore
import Testing

@Suite("Codex app-server completion")
struct CodexAppServerBridgeTests {
    @Test func usageTrackerRejectsMalformedSnapshotsAndDefaultsOldCacheWrites() {
        var tracker = CodexAppServerBridge.UsageTracker()
        let valid: JSONValue = ["inputTokens": 100, "cachedInputTokens": 20,
            "outputTokens": 10, "reasoningOutputTokens": 2, "totalTokens": 110]
        let missing: JSONValue = ["outputTokens": 10]
        let negative: JSONValue = ["inputTokens": -1, "cachedInputTokens": 0,
            "outputTokens": 0, "reasoningOutputTokens": 0]
        for invalid in [missing, negative] {
            #expect(tracker.observe(["params": ["tokenUsage": ["last": invalid, "total": valid]]]) == nil)
            #expect(tracker.observe(["params": ["tokenUsage": ["last": valid, "total": invalid]]]) == nil)
        }
        let usage = tracker.observe(["params": ["tokenUsage": ["last": valid, "total": valid]]])
        #expect(usage?.inputTokens == 80 && usage?.cacheReadTokens == 20)
        #expect(usage?.cacheWriteTokens == 0 && usage?.totalTokens == 110)
    }
    @Test(arguments: ["item/started", "item/updated", "item/completed"])
    func reportsCamelCaseChildStatusSnapshots(_ method: String) {
        let turn = AgentTurnRequest(sessionID: SessionID(), providerID: .codex, prompt: "test")
        let item: JSONValue = ["id": "collab", "type": "collabAgentToolCall",
            "status": "completed", "agentsStates": [
                "a": ["status": "pendingInit"], "b": ["status": "notFound"],
                "c": ["status": "running"],
            ]]
        let events = CodexAppServerBridge.events(["method": .string(method), "params": ["item": item]], turn: turn)
        let reports = events.compactMap { event -> SubagentStatusReport? in
            if case .subagentStatusReported(let report) = event { return report }
            return nil
        }
        #expect(reports.map(\.agentThreadID) == ["a", "b", "c"])
        #expect(reports.map(\.status) == [.pendingInit, .notFound, .running])
    }
    @Test(arguments: ["completed", "failed", "interrupted"])
    func preservesStandardCollabAgentResults(_ status: String) throws {
        let turn = AgentTurnRequest(sessionID: SessionID(), providerID: .codex, prompt: "test")
        let item: JSONValue = [
            "id": "collab-call", "type": "collabAgentToolCall", "tool": "wait",
            "senderThreadId": "parent", "receiverThreadIds": ["child"],
            "status": .string(status),
            "agentsStates": ["child": ["status": "completed", "message": "QA_CHILD_DONE"]],
        ]
        let call = try #require(CodexAppServerBridge.events([
            "method": "item/started", "params": ["item": item],
        ], turn: turn).compactMap(\.toolCallStarted).first)
        let result = try #require(CodexAppServerBridge.events([
            "method": "item/completed", "params": ["item": item],
        ], turn: turn).compactMap(\.toolCallCompleted).first)
        #expect(result.toolCallID == call.id)
        #expect(result.isError == (status != "completed"))
        let states = try JSONDecoder().decode(JSONValue.self, from: Data(result.content.utf8))
        #expect(states["child"]?["message"]?.stringValue == "QA_CHILD_DONE")
    }
    @Test(arguments: [true, false])
    func retryableErrorsDoNotFinishTheTurn(_ willRetry: Bool) throws {
        let turn = AgentTurnRequest(sessionID: SessionID(), providerID: .codex, prompt: "test")
        let frame: JSONValue = [
            "method": "error",
            "params": ["error": ["message": "Reconnecting... 2/5"], "willRetry": .bool(willRetry)],
        ]
        let event = try #require(CodexAppServerBridge.events(frame, turn: turn).first)
        if willRetry {
            guard case .statusUpdate(let text) = event else {
                Issue.record("Retryable errors must stay non-terminal")
                return
            }
            #expect(text == "Reconnecting... 2/5")
        } else {
            guard case .turnFailed = event else {
                Issue.record("Final errors must remain terminal")
                return
            }
        }
    }

    @Test(arguments: [SessionRecord.CodexApprovalMode.manual, .automatic])
    func explicitlyOverridesReviewerOnResumedTurns(_ mode: SessionRecord.CodexApprovalMode) throws {
        let turn = AgentTurnRequest(sessionID: SessionID(), providerID: .codex, prompt: "test")
        let data = try CodexAppServerBridge.startTurn(
            threadID: "resumed-thread", turn: turn, approvalMode: mode
        )
        let frame = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(frame["params"]?["threadId"]?.stringValue == "resumed-thread")
        #expect(frame["params"]?["clientUserMessageId"]?.stringValue == turn.turnID.uuidString)
        #expect(frame["params"]?["approvalPolicy"]?.stringValue == "on-request")
        #expect(frame["params"]?["approvalsReviewer"]?.stringValue
            == (mode == .manual ? "user" : "auto_review"))
        #expect(frame["params"]?["sandboxPolicy"]?["type"]?.stringValue == "workspaceWrite")
    }

    @Test func parsesSubagentActivityNotifications() throws {
        let turn = AgentTurnRequest(sessionID: SessionID(), providerID: .codex, prompt: "test")
        let started: JSONValue = [
            "method": "item/started",
            "params": ["item": [
                "id": "start-event",
                "type": "subagentActivity",
                "kind": "started",
                "agentThreadId": "agent-thread-1",
            ]],
        ]
        let startCall = try #require(
            CodexAppServerBridge.events(started, turn: turn).compactMap(\.toolCallStarted).first
        )
        #expect(startCall.id == ToolCallID("agent-thread-1"))
        #expect(startCall.name == "Subagent")

        let completed: JSONValue = [
            "method": "item/completed",
            "params": ["item": [
                "id": "complete-event",
                "type": "subagentActivity",
                "kind": "completed",
                "agentThreadId": "agent-thread-1",
            ]],
        ]
        let result = try #require(
            CodexAppServerBridge.events(completed, turn: turn).compactMap(\.toolCallCompleted).first
        )
        #expect(result.toolCallID == ToolCallID("agent-thread-1"))
        #expect(result.isError == false)
    }

    @Test(arguments: ["completed", "interrupted", "failed", "inProgress", "unexpected", ""])
    func completionRequiresExplicitTerminalStatus(_ status: String) throws {
        let turn = AgentTurnRequest(sessionID: SessionID(), providerID: .codex, prompt: "test")
        let frame: JSONValue = [
            "method": "turn/completed",
            "params": ["turn": status.isEmpty ? [:] : ["status": .string(status)]],
        ]
        let event = try #require(CodexAppServerBridge.events(frame, turn: turn).first)
        switch event {
        case .turnCompleted(let summary):
            #expect(status == "completed" || status == "interrupted")
            #expect(summary.stopReason == (status == "completed" ? .completed : .cancelled))
        case .turnFailed:
            #expect(status != "completed" && status != "interrupted")
        default:
            Issue.record("Completion frame must produce a terminal result")
        }
    }
}
