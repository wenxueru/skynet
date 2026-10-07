import Foundation
import SkynetCore
import Testing

@Suite("Codex adapter")
struct CodexAdapterTests {
    let adapter = CodexAdapter()
    let provider = AgentProviderDescriptor.codex

    func turn(
        prompt: String = "fix the bug",
        modelID: ModelID? = nil,
        effort: ReasoningEffort? = nil,
        workingDirectory: String? = nil,
        attachments: [ImageAttachment] = [],
        resumeToken: String? = nil
    ) -> AgentTurnRequest {
        AgentTurnRequest(
            sessionID: SessionID(),
            providerID: .codex,
            prompt: prompt,
            attachments: attachments,
            modelID: modelID,
            effort: effort,
            workingDirectory: workingDirectory,
            resumeToken: resumeToken
        )
    }

    // MARK: Argument construction

    @Test func baseArgumentsRunExecWithJSON() throws {
        let arguments = try adapter.buildArguments(
            provider: provider,
            turn: turn(),
            permissions: .askEverything,
            interactivePermissions: false
        )
        #expect(arguments.first == "exec")
        #expect(arguments.contains("--json"))
        // The prompt is the positional argument, last.
        #expect(arguments.last == "fix the bug")
    }

    @Test func workingDirectoryModelAndEffortMapToFlags() throws {
        let arguments = try adapter.buildArguments(
            provider: provider,
            turn: turn(
                modelID: ModelID("gpt-5.1-codex"),
                effort: .low,
                workingDirectory: "/tmp/repo"
            ),
            permissions: .askEverything,
            interactivePermissions: false
        )
        let joined = arguments.joined(separator: " ")
        #expect(joined.contains("--cd /tmp/repo"))
        #expect(joined.contains("--model gpt-5.1-codex"))
        #expect(joined.contains("-c model_reasoning_effort=low"))
    }

    @Test func defaultEffectMapsOntoSandboxModes() throws {
        let deny = try adapter.buildArguments(
            provider: provider,
            turn: turn(),
            permissions: PermissionPolicy(rules: [], defaultEffect: .deny),
            interactivePermissions: false
        )
        #expect(deny.contains("--sandbox") && deny.contains("read-only"))

        let ask = try adapter.buildArguments(
            provider: provider,
            turn: turn(),
            permissions: .askEverything,
            interactivePermissions: false
        )
        #expect(ask.contains("--approve-for-me"))

        let allow = try adapter.buildArguments(
            provider: provider,
            turn: turn(),
            permissions: PermissionPolicy(rules: [], defaultEffect: .allow),
            interactivePermissions: false
        )
        #expect(allow.contains("danger-full-access"))
        #expect(allow.contains("--ask-for-approval"))
        #expect(allow.contains("never"))
    }

    @Test func existingThreadUsesExecResume() throws {
        let token = "01900000-0000-7000-8000-000000000000"
        let arguments = try adapter.buildArguments(
            provider: provider,
            turn: turn(prompt: "continue", resumeToken: token),
            permissions: .askEverything,
            interactivePermissions: false
        )

        #expect(Array(arguments.suffix(3)) == ["resume", token, "continue"])
    }

    @Test func attachmentsAreRejected() {
        let attachment = ImageAttachment(data: Data([1]), mediaType: "image/png")
        #expect(throws: SkynetError.self) {
            _ = try adapter.buildArguments(
                provider: provider,
                turn: turn(attachments: [attachment]),
                permissions: .askEverything,
                interactivePermissions: false
            )
        }
    }

    @Test func stdinIsUnused() throws {
        #expect(
            try adapter.launchStdin(provider: provider, turn: turn()) == nil
        )
        #expect(adapter.permissionResponseStdin(
            PermissionResponse(requestID: "r", decision: .allow)
        ) == nil)
    }

    // MARK: Legacy frame parsing

    @Test func parsesTaskStartedAsSessionToken() {
        let line = #"{"id":"thread_9","msg":{"type":"task_started"}}"#
        let events = adapter.parseOutputLine(line, turn: turn())
        #expect(events.compactMap(\.sessionToken) == ["thread_9"])
    }

    @Test func parsesAgentMessage() {
        let line = #"{"id":"t1","msg":{"type":"agent_message","message":"Hello from Codex"}}"#
        let events = adapter.parseOutputLine(line, turn: turn(modelID: ModelID("gpt-5.1-codex")))
        let message = events.compactMap(\.message).first
        #expect(message?.origin == .agent)
        #expect(message?.plainText == "Hello from Codex")
        #expect(message?.providerID == .codex)
        #expect(message?.modelID == ModelID("gpt-5.1-codex"))
    }

    @Test func parsesAgentReasoningAsThinkingDelta() {
        let line = #"{"id":"t1","msg":{"type":"agent_reasoning","text":"considering options"}}"#
        let events = adapter.parseOutputLine(line, turn: turn())
        guard case .thinkingDelta(let text) = events.first else {
            Issue.record("expected thinking delta")
            return
        }
        #expect(text == "considering options")
    }

    @Test func parsesExecCommandBeginAndEnd() {
        let begin = #"{"id":"t1","msg":{"type":"exec_command_begin","call_id":"call_1","command":"ls -la"}}"#
        var events = adapter.parseOutputLine(begin, turn: turn())
        let started = events.compactMap(\.toolCallStarted).first
        #expect(started?.name == "Bash")
        #expect(started?.input["command"]?.stringValue == "ls -la")

        let end = #"{"id":"t1","msg":{"type":"exec_command_end","call_id":"call_1","stdout":"total 0","stderr":"","exit_code":0}}"#
        events = adapter.parseOutputLine(end, turn: turn())
        let result = events.compactMap(\.toolCallCompleted).first
        #expect(result?.toolCallID == ToolCallID("call_1"))
        #expect(result?.content == "total 0")
        #expect(result?.isError == false)

        let failedEnd = #"{"id":"t1","msg":{"type":"exec_command_end","call_id":"call_1","stdout":"","stderr":"nope","exit_code":127}}"#
        events = adapter.parseOutputLine(failedEnd, turn: turn())
        let failure = events.compactMap(\.toolCallCompleted).first
        #expect(failure?.isError == true)
        #expect(failure?.content == "nope")
    }

    @Test func parsesMcpToolCallsWithNormalizedNames() {
        let begin = #"{"id":"t1","msg":{"type":"mcp_tool_call_begin","call_id":"call_2","server":"github","tool":"create_issue","arguments":{"title":"x"}}}"#
        var events = adapter.parseOutputLine(begin, turn: turn())
        #expect(events.compactMap(\.toolCallStarted).first?.name == "mcp__github__create_issue")

        let end = #"{"id":"t1","msg":{"type":"mcp_tool_call_end","call_id":"call_2","output":"created"}}"#
        events = adapter.parseOutputLine(end, turn: turn())
        #expect(events.compactMap(\.toolCallCompleted).first?.content == "created")
    }

    @Test func parsesTokenCount() {
        let line = #"{"id":"t1","msg":{"type":"token_count","input_tokens":100,"cached_input_tokens":20,"output_tokens":50,"reasoning_output_tokens":10}}"#
        let events = adapter.parseOutputLine(line, turn: turn())
        let usage = events.compactMap(\.usage).first
        #expect(usage?.inputTokens == 80)
        #expect(usage?.cacheReadTokens == 20)
        #expect(usage?.outputTokens == 50)
        #expect(usage?.reasoningTokens == 10)
        #expect(usage?.totalTokens == 150)
    }

    @Test func parsesTaskComplete() {
        let line = #"{"id":"t1","msg":{"type":"task_complete","last_message":"All done"}}"#
        let turn = self.turn()
        let events = adapter.parseOutputLine(line, turn: turn)
        let summary = events.compactMap(\.turnCompleted).first
        #expect(summary?.stopReason == .completed)
        #expect(summary?.finalText == "All done")
        #expect(summary?.context.turnID == turn.turnID)
    }

    @Test func parsesErrorFrame() {
        let line = #"{"id":"t1","msg":{"type":"error","message":"model refused"}}"#
        let events = adapter.parseOutputLine(line, turn: turn())
        let failure = events.compactMap(\.turnFailed).first
        #expect(failure != nil)
        guard case .executionFailed(let reason) = failure?.error else {
            Issue.record("expected executionFailed")
            return
        }
        #expect(reason == "model refused")
    }

    @Test func unknownLegacyFramesSurfaceAsUnhandled() {
        let line = #"{"id":"t1","msg":{"type":"some_future_event","x":1}}"#
        let events = adapter.parseOutputLine(line, turn: turn())
        #expect(events.count == 1)
        #expect(events[0].unhandled?["msg"]?["type"]?.stringValue == "some_future_event")
    }

    // MARK: Thread frame parsing

    @Test func parsesThreadStarted() {
        let line = #"{"type":"thread.started","thread_id":"th_1"}"#
        let events = adapter.parseOutputLine(line, turn: turn())
        #expect(events.compactMap(\.sessionToken) == ["th_1"])
    }

    @Test func parsesCommandExecutionItems() {
        let started = #"{"type":"item.started","item":{"id":"i1","type":"command_execution","command":"pwd"}}"#
        var events = adapter.parseOutputLine(started, turn: turn())
        #expect(events.compactMap(\.toolCallStarted).first?.name == "Bash")

        let completed = #"{"type":"item.completed","item":{"id":"i1","type":"command_execution","aggregated_output":"/tmp","exit_code":0}}"#
        events = adapter.parseOutputLine(completed, turn: turn())
        let result = events.compactMap(\.toolCallCompleted).first
        #expect(result?.content == "/tmp")
        #expect(result?.isError == false)
    }

    @Test func parsesCodexSubagentItemsForActivityTracking() {
        let started = #"{"type":"item.started","item":{"id":"agent-1","type":"collab_agent_tool_call","tool":"spawn_agent","prompt":"Inspect the tests"}}"#
        var events = adapter.parseOutputLine(started, turn: turn())
        let call = events.compactMap(\.toolCallStarted).first
        #expect(call?.name == "CodexAgent")
        #expect(call?.input["prompt"]?.stringValue == "Inspect the tests")

        let completed = #"{"type":"item.completed","item":{"id":"agent-1","type":"collab_agent_tool_call","status":"completed","result":"Done"}}"#
        events = adapter.parseOutputLine(completed, turn: turn())
        #expect(events.compactMap(\.toolCallCompleted).first?.toolCallID == ToolCallID("agent-1"))
    }

    @Test(arguments: ["completed", "failed"])
    func parsesStandardExecCollabToolLifecycleAndAgentStates(_ status: String) throws {
        let started = #"{"type":"item.started","item":{"id":"collab-1","type":"collab_tool_call","tool":"spawn_agent","sender_thread_id":"parent","receiver_thread_ids":[],"prompt":"Read-only QA","agents_states":{},"status":"in_progress"}}"#
        let call = try #require(adapter.parseOutputLine(started, turn: turn()).compactMap(\.toolCallStarted).first)
        #expect(call.id == ToolCallID("collab-1"))
        #expect(call.name == "CodexAgent")
        #expect(call.input["tool"]?.stringValue == "spawn_agent")
        let completed = #"{"type":"item.completed","item":{"id":"collab-1","type":"collab_tool_call","tool":"wait","sender_thread_id":"parent","receiver_thread_ids":["child"],"prompt":null,"agents_states":{"child":{"status":"completed","message":"QA_CHILD_DONE"}},"status":"\#(status)"}}"#
        let result = try #require(adapter.parseOutputLine(completed, turn: turn()).compactMap(\.toolCallCompleted).first)
        #expect(result.toolCallID == call.id)
        #expect(result.isError == (status == "failed"))
        let states = try JSONDecoder().decode(JSONValue.self, from: Data(result.content.utf8))
        #expect(states["child"]?["message"]?.stringValue == "QA_CHILD_DONE")
        #expect(states["child"]?["status"]?.stringValue == "completed")
    }

    @Test func parsesSubAgentActivityLifecycleForActivityTracking() {
        let started = #"{"type":"item.completed","item":{"id":"start-event","type":"SubAgentActivity","kind":"started","agent_thread_id":"agent-thread-1"}}"#
        var events = adapter.parseOutputLine(started, turn: turn())
        if case .subagentStatusReported(let report) = events.first {
            #expect(report == .init(agentThreadID: "agent-thread-1", status: .running))
        } else { Issue.record("expected ephemeral running report") }
        #expect(events.count == 1)

        let completed = #"{"type":"item.completed","item":{"id":"complete-event","type":"SubAgentActivity","kind":"completed","agent_thread_id":"agent-thread-1"}}"#
        events = adapter.parseOutputLine(completed, turn: turn())
        if case .subagentStatusReported(let report) = events.first {
            #expect(report == .init(agentThreadID: "agent-thread-1", status: .completed))
        } else { Issue.record("expected ephemeral completed report") }
        #expect(events.count == 1)
    }

    @Test(arguments: SubagentStatusReport.Status.allCases)
    func reportsActualExecChildStateSeparatelyFromToolCompletion(_ status: SubagentStatusReport.Status) throws {
        let line = #"{"type":"item.completed","item":{"id":"collab-status","type":"collab_tool_call","tool":"wait","status":"completed","agents_states":{"child":{"status":"\#(status.rawValue)","message":"child report"}}}}"#
        let events = adapter.parseOutputLine(line, turn: turn())
        let reports = events.compactMap { event -> SubagentStatusReport? in
            if case .subagentStatusReported(let report) = event { return report }
            return nil
        }
        #expect(reports == [SubagentStatusReport(agentThreadID: "child", status: status, message: "child report")])
        #expect(events.compactMap(\.toolCallCompleted).count == 1)
        #expect(events.compactMap(\.toolCallStarted).isEmpty)
    }

    @Test(arguments: ["item.started", "item.updated", "item.completed"])
    func reportsMultipleChildrenAndPreservesUnknownStates(_ phase: String) {
        let line = #"{"type":"\#(phase)","item":{"id":"collab-status","type":"collab_tool_call","tool":"wait","status":"completed","receiver_thread_ids":["unreported"],"agents_states":{"b":{"status":"running"},"a":{"status":"completed","message":null},"unknown":{"status":"future_state"}}}}"#
        let events = adapter.parseOutputLine(line, turn: turn())
        let reports = events.compactMap { event -> SubagentStatusReport? in
            if case .subagentStatusReported(let report) = event { return report }
            return nil
        }
        #expect(reports.map(\.agentThreadID) == ["a", "b"])
        #expect(reports.map(\.status) == [.completed, .running])
        #expect(events.compactMap(\.unhandled).count == 1)
    }

    @Test func parsesAgentMessageAndReasoningItems() {
        let message = #"{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"the answer"}}"#
        var events = adapter.parseOutputLine(message, turn: turn())
        #expect(events.compactMap(\.message).first?.plainText == "the answer")

        let reasoning = #"{"type":"item.completed","item":{"id":"i3","type":"reasoning","text":"hmm"}}"#
        events = adapter.parseOutputLine(reasoning, turn: turn())
        guard case .thinkingDelta(let text) = events.first else {
            Issue.record("expected thinking delta")
            return
        }
        #expect(text == "hmm")
    }

    @Test func parsesTurnCompletedWithUsage() {
        let line = #"{"type":"turn.completed","usage":{"input_tokens":7,"output_tokens":3}}"#
        let events = adapter.parseOutputLine(line, turn: turn())
        let summary = events.compactMap(\.turnCompleted).first
        #expect(summary?.usage?.inputTokens == 7)
        #expect(summary?.stopReason == .completed)
    }

    @Test func completionDoesNotCountCachedInputTwice() throws {
        let events = adapter.parseOutputLine(
            #"{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":20,"cache_write_input_tokens":5,"output_tokens":10,"reasoning_output_tokens":2}}"#,
            turn: turn()
        )
        let usage = try #require(events.compactMap(\.turnCompleted).first?.usage)
        #expect(usage.inputTokens == 75)
        #expect(usage.cacheReadTokens == 20 && usage.cacheWriteTokens == 5)
        #expect(usage.outputTokens == 10 && usage.reasoningTokens == 2)
        #expect(usage.totalTokens == 110)
    }

    @Test func unparseableAndEmptyLinesBehaveLikeClaudeAdapter() {
        #expect(adapter.parseOutputLine("", turn: turn()).isEmpty)
        let events = adapter.parseOutputLine("garbage", turn: turn())
        #expect(events[0].unhandled?["_skynetNote"]?.stringValue == "unparseable output line")
    }
}
