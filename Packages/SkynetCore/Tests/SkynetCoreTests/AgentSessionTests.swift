import Foundation
import SkynetCore
import SkynetCoreDoubles
import Testing

/// Shared Claude Code stream-json frames for session-level scripts.
enum ClaudeFrames {
    static let initialization = #"{"type":"system","subtype":"init","session_id":"sess-123","model":"claude-opus-4-8"}"#
    static let assistantText = #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Here is the answer"}],"usage":{"input_tokens":10,"output_tokens":5}}}"#
    static let resultSuccess = #"{"type":"result","subtype":"success","result":"Here is the answer","session_id":"sess-123","duration_ms":1500,"usage":{"input_tokens":10,"output_tokens":5}}"#
    static let controlRequest = """
    {"type":"control_request","request_id":"req-7","payload":{"type":"permission_request","tool_name":"Bash","input":{"command":"rm -rf /tmp/x"}}}
    """
}

@Suite("Agent session")
struct AgentSessionTests {
    @Test func cancelledCallerDoesNotStartOrPersistATurn() async throws {
        let backend = ScriptedExecutionBackend()
        let store = InMemoryStore()
        let session = try makeSession(provider: .codex, backend: backend, store: store)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                let stream = try await session.send("cancelled caller fixture")
                for try await _ in stream {}
                return false
            } catch is CancellationError {
                return true
            }
        }
        let rejected = try await task.value
        let record = await session.record
        #expect(rejected)
        #expect(backend.launchedRequests.isEmpty)
        #expect(try store.loadMessages(for: record.id).isEmpty)
        #expect(record.messageCount == 0 && record.status == .idle)
    }

    private func makeSession(
        provider: AgentProviderDescriptor = .claudeCode,
        record: SessionRecord? = nil,
        backend: any ExecutionBackend,
        permissions: PermissionPolicy = .askEverything,
        responder: (any PermissionResponder)? = nil,
        store: (any PersistenceStore)? = InMemoryStore(),
        policy: PlatformExecutionPolicy = .macOS,
        notifier: (any Notifier)? = nil
    ) throws -> AgentSession {
        var notifications = EventNotificationRouter()
        if let notifier {
            notifications = EventNotificationRouter(notifiers: [notifier])
        }
        return try AgentSession(
            record: record ?? SessionRecord(providerID: provider.id),
            configuration: .init(
                provider: provider,
                backend: backend,
                policy: policy,
                permissions: permissions,
                permissionResponder: responder,
                store: store,
                notifications: notifications
            )
        )
    }

    // MARK: Happy path

    @Test(arguments: [0, 1, 2])
    func codexExecCumulativeUsageReplacesStoredTotals(initialMultiplier: Int) async throws {
        // CLI 0.156.1 turn.completed uses ThreadTokenUsage.total, not .last.
        // Values come from the scoped U1 provider-token-count audit.
        let first = #"{"type":"turn.completed","usage":{"input_tokens":39312046,"cached_input_tokens":36785920,"cache_write_input_tokens":0,"output_tokens":55535,"reasoning_output_tokens":23081}}"#
        let second = #"{"type":"turn.completed","usage":{"input_tokens":39312166,"cached_input_tokens":36785940,"cache_write_input_tokens":0,"output_tokens":55545,"reasoning_output_tokens":23083}}"#
        let backend = ScriptedExecutionBackend(scripts: [
            .init(stdoutLines: [#"{"type":"thread.started","thread_id":"usage-exec-thread"}"#, first, first]),
            .init(stdoutLines: [#"{"type":"thread.started","thread_id":"usage-exec-thread"}"#, second]),
            .init(stdoutLines: [#"{"type":"thread.started","thread_id":"usage-exec-thread"}"#,
                                #"{"type":"turn.completed"}"#]),
        ])
        var initial = SessionRecord(providerID: .codex, providerResumeToken: "usage-exec-thread")
        initial.totalUsage = TokenUsage(
            inputTokens: 2509741 * initialMultiplier, cacheReadTokens: 36733952 * initialMultiplier,
            cacheWriteTokens: 0, outputTokens: 55510 * initialMultiplier,
            reasoningTokens: 23073 * initialMultiplier
        )
        let store = InMemoryStore()
        let session = try makeSession(provider: .codex, record: initial, backend: backend, store: store)
        _ = try await collectEvents(try await session.send("own cumulative usage fixture one"))
        let firstRecord = await session.record
        #expect(firstRecord.totalUsage == TokenUsage(
            inputTokens: 2526126, cacheReadTokens: 36785920, cacheWriteTokens: 0,
            outputTokens: 55535, reasoningTokens: 23081
        ))
        // Recreate the actor as the UI does for another send; resumed totals
        // must not be re-added and missing usage must not clear them.
        let resumed = try makeSession(provider: .codex, record: firstRecord, backend: backend, store: store)
        _ = try await collectEvents(try await resumed.send("own cumulative usage fixture two"))
        let secondRecord = await resumed.record
        #expect(secondRecord.totalUsage == TokenUsage(
            inputTokens: 2526226, cacheReadTokens: 36785940, cacheWriteTokens: 0,
            outputTokens: 55545, reasoningTokens: 23083
        ))
        _ = try await collectEvents(try await resumed.send("own missing usage fixture"))
        let finalRecord = await resumed.record
        #expect(finalRecord.totalUsage == secondRecord.totalUsage)
        #expect(finalRecord.status == .idle)
        #expect(try store.loadSessions(matching: nil).first?.totalUsage == finalRecord.totalUsage)
        #expect(backend.launchedRequests.allSatisfy { $0.arguments.first == "exec" })
    }

    @Test(arguments: [SessionRecord.CodexApprovalMode.manual, .automatic], ["completed", "failed", "interrupted"])
    func codexAppServerUsagePersistsOnceForMatchingTurn(
        mode: SessionRecord.CodexApprovalMode, status: String
    ) async throws {
        let first = #"{"inputTokens":5100,"cachedInputTokens":1020,"cacheWriteInputTokens":0,"outputTokens":510,"reasoningOutputTokens":102,"totalTokens":5610}"#
        let second = #"{"inputTokens":5150,"cachedInputTokens":1030,"cacheWriteInputTokens":0,"outputTokens":515,"reasoningOutputTokens":103,"totalTokens":5665}"#
        func usage(_ total: String, thread: String = "usage-thread", turn: String = "usage-turn") -> String {
            #"{"method":"thread/tokenUsage/updated","params":{"threadId":"\#(thread)","turnId":"\#(turn)","tokenUsage":{"total":\#(total),"last":{"inputTokens":100,"cachedInputTokens":20,"cacheWriteInputTokens":0,"outputTokens":10,"reasoningOutputTokens":2,"totalTokens":110}}}}"#
        }
        let backend = ScriptedExecutionBackend(scripts: [.init(onStdin: { data, process in
            let frame = try! JSONDecoder().decode(JSONValue.self, from: data)
            switch frame["method"]?.stringValue {
            case "initialize": process.emitStdout(#"{"id":0,"result":{}}"#)
            case "thread/start": process.emitStdout(#"{"id":1,"result":{"thread":{"id":"usage-thread"}}}"#)
            case "turn/start":
                process.emitStdout(usage(first, turn: "previous-turn"))
                process.emitStdout(#"{"id":2,"result":{"turn":{"id":"usage-turn"}}}"#)
                process.emitStdout(usage(first, thread: "other-fixture-thread"))
                process.emitStdout(usage(first, turn: "previous-turn"))
                process.emitStdout(usage(first))
                process.emitStdout(usage(first)) // Replayed snapshot, not another response.
                process.emitStdout(usage(second)) // Difference covers the next model response.
                process.emitStdout(usage(first)) // Older same-turn snapshot must not regress totals.
                process.emitStdout(#"{"method":"turn/completed","params":{"turn":{"status":"\#(status)"}}}"#)
                process.finishStdout()
            default: break
            }
        })])
        var initial = SessionRecord(providerID: .codex, codexApprovalMode: mode)
        initial.totalUsage = TokenUsage(inputTokens: 1000, cacheReadTokens: 200, outputTokens: 100)
        let store = InMemoryStore()
        let session = try makeSession(provider: .codex, record: initial, backend: backend, store: store)
        let events = try await collectEvents(try await session.send(
            "own usage fixture", attachments: [ImageAttachment(data: Data([1]), mediaType: "image/png")]
        ))
        let record = await session.record
        let snapshots = events.compactMap(\.usage)
        #expect(snapshots.count == 2)
        #expect(snapshots.last?.inputTokens == 120)
        #expect(snapshots.last?.cacheReadTokens == 30)
        #expect(snapshots.last?.outputTokens == 15)
        #expect(snapshots.last?.reasoningTokens == 3)
        #expect(record.totalUsage.inputTokens == 1120)
        #expect(record.totalUsage.cacheReadTokens == 230)
        #expect(record.totalUsage.outputTokens == 115)
        #expect(record.totalUsage.totalTokens == 1465)
        #expect(try store.loadSessions(matching: nil).first(where: { $0.id == record.id })?.totalUsage
                == record.totalUsage)
    }

    @Test(arguments: [PermissionResponse.Decision.allow, .allowAlways, .deny], [false, true])
    func claudeSDKApprovalReturnsEffectiveInputUnlessDenied(
        decision: PermissionResponse.Decision, editInput: Bool
    ) async throws {
        let backend = ScriptedExecutionBackend(scripts: [.init(onStdin: { data, process in
            guard let frame = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                Issue.record("invalid approval fixture stdin")
                process.finishStdout()
                return
            }
            if frame["type"]?.stringValue == "user" {
                process.emitStdout(#"{"type":"control_request","request_id":"sdk-7","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"/bin/echo QA"}}}"#)
            } else {
                #expect(frame["type"]?.stringValue == "control_response")
                #expect(frame["response"]?["subtype"]?.stringValue == "success")
                #expect(frame["response"]?["request_id"]?.stringValue == "sdk-7")
                process.emitStdout(ClaudeFrames.resultSuccess)
                process.finishStdout()
            }
        })])
        let responder = ScriptedPermissionResponder(responses: [
            PermissionResponse(
                requestID: "", decision: decision,
                updatedInput: editInput ? ["command": "/bin/echo EDITED"] : nil
            )
        ])
        let session = try makeSession(backend: backend, responder: responder)
        let events = try await collectEvents(try await session.send("offline approval fixture"))
        #expect(events.compactMap(\.turnCompleted).first?.finalText == "Here is the answer")
        #expect(responder.requests.first?.toolName == "Bash")
        let data = try #require(backend.launchedProcesses.first?.stdinWrites.last)
        let frame = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(frame["response"]?["request_id"]?.stringValue == "sdk-7")
        let answer = frame["response"]?["response"]
        #expect(answer?["behavior"]?.stringValue == (decision == .deny ? "deny" : "allow"))
        if decision == .deny {
            #expect(answer?["updatedInput"] == nil)
        } else {
            #expect(answer?["updatedInput"]?["command"]?.stringValue
                == (editInput ? "/bin/echo EDITED" : "/bin/echo QA"))
        }
    }

    @Test(arguments: [PermissionRule.Effect.allow, .deny])
    func claudeSDKPolicyRepliesWithoutInteractiveResponder(effect: PermissionRule.Effect) async throws {
        let backend = ScriptedExecutionBackend(scripts: [.init(stdoutLines: [
            #"{"type":"control_request","request_id":"policy-7","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"/bin/echo QA"}}}"#,
            ClaudeFrames.resultSuccess,
        ])])
        let session = try makeSession(
            backend: backend, permissions: PermissionPolicy(rules: [], defaultEffect: effect)
        )
        _ = try await collectEvents(try await session.send("offline policy fixture"))
        let data = try #require(backend.launchedProcesses.first?.stdinWrites.last)
        let frame = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(frame["response"]?["request_id"]?.stringValue == "policy-7")
        let answer = frame["response"]?["response"]
        #expect(answer?["behavior"]?.stringValue == effect.rawValue)
        #expect(answer?["updatedInput"] == (effect == .allow ? ["command": "/bin/echo QA"] : nil))
    }

    @Test(arguments: [SessionRecord.CodexApprovalMode.manual, .automatic])
    func codexImageUsesNativeAppServerInput(mode: SessionRecord.CodexApprovalMode) async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(onStdin: { data, process in
                let request = String(decoding: data, as: UTF8.self)
                let methods = request.split(separator: "\n").compactMap {
                    try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
                }.compactMap { $0["method"]?.stringValue }
                if methods.contains("initialize") {
                    process.emitStdout(#"{"id":0,"result":{}}"#)
                } else if methods.contains("thread/start") {
                    process.emitStdout(#"{"id":1,"result":{"thread":{"id":"thread-image"}}}"#)
                } else if methods.contains("turn/start") {
                    process.emitStdout(#"{"id":2,"result":{"turn":{"id":"turn-image"}}}"#)
                    process.emitStdout(#"{"method":"turn/completed","params":{"turn":{"status":"completed"}}}"#)
                    process.finishStdout()
                }
            })
        ])
        let record = SessionRecord(providerID: .codex, codexApprovalMode: mode)
        let session = try makeSession(provider: .codex, record: record, backend: backend)

        let events = try await collectEvents(try await session.send(
            "", attachments: [ImageAttachment(data: Data([1, 2, 3]), mediaType: "image/png")]
        ))

        let request = try #require(backend.launchedProcesses.first?.stdinWrites.last)
        let frame = try JSONDecoder().decode(JSONValue.self, from: request)
        #expect(frame["method"]?.stringValue == "turn/start")
        let user = try #require(events.compactMap(\.message).first(where: { $0.origin == .user }))
        #expect(frame["params"]?["clientUserMessageId"]?.stringValue == user.id.description)
        #expect(frame["params"]?["input"]?[0]?["type"]?.stringValue == "image")
        #expect(frame["params"]?["input"]?[0]?["url"]?.stringValue
            == "data:image/png;base64,AQID")
        #expect(frame["params"]?["approvalsReviewer"]?.stringValue
            == (mode == .automatic ? "auto_review" : "user"))
    }

    @Test func claudeTurnProducesEventsAndPersistsTranscript() async throws {
        let backend = ScriptedExecutionBackend(
            scripts: [
                .init(stdoutLines: [ClaudeFrames.initialization, ClaudeFrames.assistantText, ClaudeFrames.resultSuccess])
            ]
        )
        let store = InMemoryStore()
        let session = try makeSession(backend: backend, store: store)

        let stream = try await session.send("what is 2+2")
        let events = try await collectEvents(stream)

        #expect(events.first != nil)
        if case .turnStarted = events.first {} else {
            Issue.record("turn should start first, got \(events.first ?? .unhandledEvent(raw: .null))")
        }

        let messages = events.compactMap(\.message)
        #expect(messages.count == 2)
        #expect(messages[0].origin == .user)
        #expect(messages[0].plainText == "what is 2+2")
        #expect(messages[1].origin == .agent)
        #expect(messages[1].plainText == "Here is the answer")

        #expect(events.compactMap(\.sessionToken) == ["sess-123"])
        let summary = events.compactMap(\.turnCompleted).first
        #expect(summary?.stopReason == .completed)
        #expect(summary?.finalText == "Here is the answer")
        #expect(summary?.usage?.outputTokens == 5)

        // The store saw exactly the transcript messages.
        let persisted = try store.loadMessages(for: (await session.record).id)
        #expect(persisted.count == 2)
        #expect(persisted.map(\.origin) == [.user, .agent])

        let record = await session.record
        #expect(record.status == .idle)
        #expect(record.providerResumeToken == "sess-123")
        #expect(record.totalUsage.outputTokens == 5)
        #expect(record.title == "what is 2+2")
        #expect(record.messageCount == 2)
    }

    @Test func claudeForkUsesOneShotNativeFlagAndStoresChildID() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(stdoutLines: [
                #"{"type":"system","subtype":"init","session_id":"child-456"}"#,
                #"{"type":"result","subtype":"success","result":"done","session_id":"child-456"}"#,
            ]),
        ])
        let record = SessionRecord(providerID: .claudeCode, forkSourceToken: "parent-123")
        let session = try makeSession(record: record, backend: backend)

        _ = try await collectEvents(try await session.send("continue"))

        let arguments = try #require(backend.launchedRequests.first?.arguments)
        #expect(arguments.contains("--fork-session"))
        #expect(arguments.contains("parent-123"))
        let updated = await session.record
        #expect(updated.providerResumeToken == "child-456")
        #expect(updated.forkSourceToken == nil)
    }

    @Test func launchedRequestCarriesProviderConfiguration() async throws {
        let backend = ScriptedExecutionBackend(scripts: [.init(stdoutLines: [ClaudeFrames.resultSuccess])])
        let session = try makeSession(backend: backend)

        _ = try await collectEvents(try await session.send("hi"))

        let request = backend.launchedRequests[0]
        #expect(request.executable == "claude")
        #expect(request.label.hasPrefix("claude-code:"))
        #expect(request.arguments.contains("--print"))
        #expect(request.arguments.contains("stream-json"))
        // An unset model defers to the installed provider CLI.
        #expect(!request.arguments.contains("--model"))
    }

    @Test func claudePermissionModesUseNativeCLIValues() async throws {
        for mode in SessionRecord.ClaudePermissionMode.allCases {
            let backend = ScriptedExecutionBackend(scripts: [
                .init(stdoutLines: [ClaudeFrames.resultSuccess])
            ])
            let record = SessionRecord(providerID: .claudeCode, claudePermissionMode: mode)
            let session = try makeSession(record: record, backend: backend)

            _ = try await collectEvents(try await session.send("hi"))

            let arguments = backend.launchedRequests[0].arguments
            let index = try #require(arguments.firstIndex(of: "--permission-mode"))
            #expect(arguments[index + 1] == mode.rawValue)
        }
    }

    @Test func providerDefaultArgumentsPrecedeAdapterArguments() async throws {
        let provider = AgentProviderDescriptor(
            id: ProviderID("my-wrapper"),
            kind: .claudeCodeCompatible,
            displayName: "Wrapper",
            executable: "/opt/wrapper",
            defaultArguments: ["--wrapper-flag"]
        )
        let backend = ScriptedExecutionBackend(scripts: [.init(stdoutLines: [ClaudeFrames.resultSuccess])])
        let session = try makeSession(provider: provider, backend: backend)

        _ = try await collectEvents(try await session.send("hi"))

        let arguments = backend.launchedRequests[0].arguments
        #expect(arguments.first == "--wrapper-flag")
        #expect(arguments.contains("--print"))
        #expect(backend.launchedRequests[0].executable == "/opt/wrapper")
    }

    @Test func codexTurnRunsExecJSONAndCompletes() async throws {
        let backend = ScriptedExecutionBackend(
            scripts: [
                .init(stdoutLines: [
                    #"{"id":"thread_1","msg":{"type":"task_started"}}"#,
                    #"{"id":"thread_1","msg":{"type":"agent_message","message":"fixed it"}}"#,
                    #"{"id":"thread_1","msg":{"type":"task_complete","last_message":"fixed it"}}"#,
                ])
            ]
        )
        let session = try makeSession(
            provider: .codex,
            record: SessionRecord(providerID: .codex, workingDirectory: "/tmp/skynet-qa"),
            backend: backend
        )

        let events = try await collectEvents(try await session.send("fix the bug"))

        let request = backend.launchedRequests[0]
        #expect(request.executable == "codex")
        #expect(request.arguments.first == "exec")
        #expect(request.arguments.contains("--json"))
        #expect(request.arguments.last == "fix the bug")
        #expect(!request.arguments.contains("--model"))
        #expect(request.stdinMode == .closed)
        #expect(request.arguments.contains("--cd"))
        #expect(request.arguments.contains("/tmp/skynet-qa"))
        #expect(request.workingDirectory == nil)

        #expect(events.compactMap(\.turnCompleted).first?.finalText == "fixed it")
        let record = await session.record
        #expect(record.status == .idle)
        #expect(record.providerResumeToken == "thread_1")
    }

    @Test func codexToolsPersistOnceAcrossUpdatesAndResume() async throws {
        let start = #"{"type":"item.started","item":{"id":"cmd-1","type":"command_execution","command":"pwd"}}"#
        let update = #"{"type":"item.updated","item":{"id":"cmd-1","type":"command_execution","command":"pwd"}}"#
        let end = #"{"type":"item.completed","item":{"id":"cmd-1","type":"command_execution","aggregated_output":"/tmp/qa","exit_code":0}}"#
        let backend = ScriptedExecutionBackend(scripts: [.init(stdoutLines: [
            start, update, end, end,
            #"{"type":"item.completed","item":{"id":"answer","type":"agent_message","text":"done"}}"#,
            #"{"type":"turn.completed"}"#,
        ])])
        let store = InMemoryStore()
        let session = try makeSession(provider: .codex, backend: backend, store: store)
        let events = try await collectEvents(try await session.send("check cwd"))
        let record = await session.record
        let persisted = try store.loadMessages(for: record.id)
        #expect(persisted.map(\.origin) == [.user, .agent, .toolResult, .agent])
        #expect(persisted[1].content.first?.toolCall?.id == ToolCallID("cmd-1"))
        #expect(persisted[2].content == [.toolResult(
            toolCallID: ToolCallID("cmd-1"), content: "/tmp/qa", isError: false
        )])
        #expect(record.messageCount == 4)
        #expect(events.compactMap(\.message) == persisted)
        let resumed = try makeSession(provider: .codex, record: record, backend: backend, store: store)
        try await resumed.loadPersistedTranscript()
        #expect(await resumed.messages == persisted)
    }

    @Test func childStatusSnapshotsReachConsumersWithoutFakeTranscriptToolCalls() async throws {
        let backend = ScriptedExecutionBackend(scripts: [.init(stdoutLines: [
            #"{"type":"item.started","item":{"id":"collab","type":"collab_tool_call","tool":"wait","agents_states":{"child":{"status":"running"}}}}"#,
            #"{"type":"item.completed","item":{"id":"collab","type":"collab_tool_call","tool":"wait","status":"completed","agents_states":{"child":{"status":"completed","message":"done"}}}}"#,
            #"{"type":"turn.completed"}"#,
        ])])
        let store = InMemoryStore()
        let session = try makeSession(provider: .codex, backend: backend, store: store)
        let events = try await collectEvents(try await session.send("fixture only"))
        let reports = events.compactMap { event -> SubagentStatusReport? in
            if case .subagentStatusReported(let report) = event { return report }
            return nil
        }
        #expect(reports.map(\.status) == [.running, .completed])
        let messages = try store.loadMessages(for: (await session.record).id)
        let calls = messages.flatMap(\.content).compactMap(\.toolCall)
        #expect(calls.map(\.id) == [ToolCallID("collab")])
        #expect(calls.map(\.name) == ["CodexAgent"])
        #expect(messages.map(\.origin) == [.user, .agent, .toolResult])
    }

    @Test func codexAppServerToolsPersistTheirErrorResults() async throws {
        let backend = ScriptedExecutionBackend(scripts: [.init(onStdin: { data, process in
            let frames = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
                try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
            }
            let methods = frames.compactMap { $0["method"]?.stringValue }
            if methods.contains("initialize") {
                process.emitStdout(#"{"id":0,"result":{}}"#)
            } else if methods.contains("thread/start") {
                process.emitStdout(#"{"id":1,"result":{"thread":{"id":"thread-tools"}}}"#)
            } else if methods.contains("turn/start") {
                process.emitStdout(#"{"id":2,"result":{"turn":{"id":"turn-tools"}}}"#)
                process.emitStdout(#"{"method":"item/started","params":{"item":{"id":"cmd-error","type":"commandExecution","command":"false"}}}"#)
                process.emitStdout(#"{"method":"item/completed","params":{"item":{"id":"cmd-error","type":"commandExecution","status":"failed","aggregatedOutput":"failed command"}}}"#)
                process.emitStdout(#"{"method":"turn/completed","params":{"turn":{"status":"completed"}}}"#)
                process.finishStdout()
            }
        })])
        let store = InMemoryStore()
        let session = try makeSession(provider: .codex,
            record: SessionRecord(providerID: .codex, codexApprovalMode: .manual),
            backend: backend, store: store)
        let events = try await collectEvents(try await session.send("check error"))
        let persisted = try store.loadMessages(for: (await session.record).id)
        #expect(persisted.map(\.origin) == [.user, .agent, .toolResult])
        #expect(persisted.last?.content == [.toolResult(
            toolCallID: ToolCallID("cmd-error"), content: "failed command", isError: true
        )])
        #expect(events.compactMap(\.message) == persisted)
    }

    @Test func claudeToolMessagesAreNotDuplicatedByLifecycleEvents() async throws {
        let backend = ScriptedExecutionBackend(scripts: [.init(stdoutLines: [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"pwd"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"/tmp/qa","is_error":false}]}}"#,
            ClaudeFrames.resultSuccess,
        ])])
        let store = InMemoryStore()
        let session = try makeSession(backend: backend, store: store)
        _ = try await collectEvents(try await session.send("cwd"))
        let persisted = try store.loadMessages(for: (await session.record).id)
        #expect(persisted.flatMap(\.content).compactMap(\.toolCall).count == 1)
        #expect(persisted.filter { $0.origin == .toolResult }.count == 1)
    }

    @Test func codexFastModeOverridesTheSessionServiceTier() async throws {
        for enabled in [true, false] {
            let backend = ScriptedExecutionBackend(scripts: [
                .init(stdoutLines: [#"{"id":"thread_1","msg":{"type":"task_complete","last_message":"Done"}}"#])
            ])
            let record = SessionRecord(providerID: .codex, codexFastMode: enabled)
            let session = try makeSession(provider: .codex, record: record, backend: backend)

            _ = try await collectEvents(try await session.send("hi"))

            let arguments = backend.launchedRequests[0].arguments
            #expect(arguments.contains("service_tier=\"\(enabled ? "fast" : "default")\""))
            #expect(arguments.contains("features.fast_mode=\(enabled)"))
        }
    }

    @Test(arguments: [0, 1, 2, 42], [PermissionResponse.Decision.allow, .deny])
    func manualCodexApprovalRoundTripsThroughAppServer(
        requestID: Int, decision: PermissionResponse.Decision
    ) async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(onStdin: { data, process in
                let input = String(decoding: data, as: UTF8.self)
                let methods = input.split(separator: "\n").compactMap {
                    try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
                }.compactMap { $0["method"]?.stringValue }
                if methods.contains("initialize") {
                    process.emitStdout(#"{"id":0,"result":{}}"#)
                } else if methods.contains("thread/start") {
                    process.emitStdout(#"{"id":1,"result":{"thread":{"id":"thread-manual"}}}"#)
                } else if methods.contains("turn/start") {
                    process.emitStdout(#"{"id":2,"result":{"turn":{"id":"turn-1"}}}"#)
                    process.emitStdout(#"{"method":"error","params":{"error":{"message":"Reconnecting... 2/5"},"willRetry":true}}"#)
                    process.emitStdout(#"{"id":\#(requestID),"method":"item/commandExecution/requestApproval","params":{"threadId":"thread-manual","turnId":"turn-1","itemId":"cmd-1","command":"date","reason":"Run a command"}}"#)
                } else if input.contains("decision") {
                    process.emitStdout(#"{"method":"item/completed","params":{"item":{"id":"answer-1","type":"agentMessage","text":"Done"}}}"#)
                    process.emitStdout(#"{"method":"turn/completed","params":{"turn":{"status":"completed"}}}"#)
                    process.finishStdout()
                }
            })
        ])
        let responder = ScriptedPermissionResponder(responses: [
            PermissionResponse(requestID: "", decision: decision)
        ])
        let record = SessionRecord(
            providerID: AgentProviderDescriptor.codex.id,
            codexApprovalMode: .manual
        )
        let session = try makeSession(
            provider: .codex, record: record, backend: backend, responder: responder
        )

        let events = try await collectEvents(try await session.send("Run date"))

        #expect(backend.launchedRequests[0].arguments == ["app-server", "--stdio"])
        #expect(backend.launchedRequests[0].stdinMode == .writable)
        #expect(responder.requests.count == 1)
        #expect(responder.requests.first?.id == String(requestID))
        #expect(responder.requests.first?.summary.contains("date") == true)
        #expect(backend.launchedProcesses[0].stdinWrites.contains {
            guard let frame = try? JSONDecoder().decode(JSONValue.self, from: $0) else { return false }
            return frame["id"]?.intValue == requestID
                && frame["result"]?["decision"]?.stringValue == (decision == .allow ? "accept" : "decline")
        })
        let methods = backend.launchedProcesses[0].stdinWrites.flatMap { data in
            String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
                try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))["method"]?.stringValue
            }
        }
        #expect(methods == ["initialize", "initialized", "thread/start", "turn/start"])
        let statuses: [String?] = events.compactMap { event -> String?? in
            guard case .statusUpdate(let text) = event else { return nil }
            return .some(text)
        }
        #expect(statuses == ["Reconnecting... 2/5", nil])
        #expect(events.compactMap(\.turnCompleted).count == 1)
        #expect(events.compactMap(\.message).last?.plainText == "Done")
        #expect((await session.record).providerResumeToken == "thread-manual")
    }

    @Test func resumeTokenFromFirstTurnIsPassedToTheSecond() async throws {
        let backend = ScriptedExecutionBackend(
            scripts: [
                .init(stdoutLines: [ClaudeFrames.initialization, ClaudeFrames.resultSuccess]),
                .init(stdoutLines: [ClaudeFrames.resultSuccess]),
            ]
        )
        let session = try makeSession(backend: backend)

        _ = try await collectEvents(try await session.send("first"))
        _ = try await collectEvents(try await session.send("second"))

        let secondArguments = backend.launchedRequests[1].arguments
        #expect(secondArguments.contains("--resume"))
        let resumeIndex = secondArguments.firstIndex(of: "--resume")!
        #expect(secondArguments[resumeIndex + 1] == "sess-123")
    }

    // MARK: Failure paths

    @Test(arguments: [Int32(0), Int32(1)])
    func claudeErrorResultPreservesFailureAndAllowsNextTurn(exitCode: Int32) async throws {
        let errorFrame = #"{"type":"result","subtype":"success","is_error":true,"result":"API Error: QA fixture unavailable"}"#
        let backend = ScriptedExecutionBackend(scripts: [
            .init(exitCode: exitCode, stdoutLines: [errorFrame]),
            .init(stdoutLines: [ClaudeFrames.resultSuccess]),
        ])
        let notifier = RecordingNotifier()
        let session = try makeSession(backend: backend, notifier: notifier)
        let events = try await collectEvents(try await session.send("offline error fixture"))
        #expect(events.compactMap(\.turnCompleted).isEmpty)
        #expect(events.compactMap(\.turnFailed).count == 1)
        #expect(events.compactMap(\.turnFailed).first?.error
            == .executionFailed(reason: "API Error: QA fixture unavailable"))
        #expect(await session.record.status == .failed)
        #expect(notifier.triggers == [.turnFailed])
        let recovery = try await collectEvents(try await session.send("offline recovery fixture"))
        #expect(recovery.compactMap(\.turnFailed).isEmpty)
        #expect(recovery.compactMap(\.turnCompleted).first?.finalText == "Here is the answer")
        #expect(await session.record.status == .idle)
        #expect(backend.launchedRequests.count == 2)
    }

    @Test func nonZeroExitWithoutResultFailsTheTurn() async throws {
        let backend = ScriptedExecutionBackend(
            scripts: [
                .init(exitCode: 2, stdoutLines: [], stderrLines: ["claude: command not found"])
            ]
        )
        let notifier = RecordingNotifier()
        let store = InMemoryStore()
        let session = try makeSession(backend: backend, store: store, notifier: notifier)

        let events = try await collectEvents(try await session.send("hello"))

        let failure = events.compactMap(\.turnFailed).first
        guard case .agentExited(let code, let stderr) = failure?.error else {
            Issue.record("expected agentExited, got \(String(describing: failure?.error))")
            return
        }
        #expect(code == 2)
        #expect(stderr.contains("command not found"))
        let record = await session.record
        #expect(record.status == .failed)
        // A failed turn still persisted the user's message.
        let sessionID = record.id
        #expect(try store.loadMessages(for: sessionID).count == 1)
        // Default routing notifies on failure.
        #expect(notifier.triggers == [.turnFailed])
    }

    @Test func codexActiveWriterConflictWaitsAndRetriesSameSession() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(
                exitCode: 1,
                stderrLines: ["thread-store conflict: thread abc already has an active writer"]
            ),
            .init(
                exitCode: 1,
                stderrLines: ["thread-store conflict: thread abc already has an active writer"]
            ),
            .init(stdoutLines: [#"{"id":"thread_expected","msg":{"type":"task_complete","last_message":"Done"}}"#]),
        ])
        let store = InMemoryStore()
        let record = SessionRecord(providerID: .codex, providerResumeToken: "thread_expected")
        let session = try makeSession(provider: .codex, record: record, backend: backend, store: store)

        let events = try await collectEvents(try await session.send("hello"))

        let requests = backend.launchedRequests
        #expect(requests.count == 3)
        #expect(requests[0].arguments == requests[1].arguments)
        #expect(requests[1].arguments == requests[2].arguments)
        #expect(requests[0].arguments.contains("thread_expected"))
        let statuses = events.compactMap { event -> String? in
            guard case .statusUpdate(let status) = event else { return nil }
            return status ?? "<cleared>"
        }
        #expect(statuses == [
            "Waiting for this Codex session to finish…",
            "<cleared>",
        ])
        #expect(events.compactMap(\.turnFailed).isEmpty)
        #expect(events.compactMap(\.turnCompleted).count == 1)
        #expect(try store.loadMessages(for: record.id).filter { $0.origin == .user }.count == 1)
        #expect(await session.record.status == .idle)
    }

    @Test func codexActiveWriterConflictOnStdoutWaitsAndRetriesSameSession() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(
                exitCode: 0,
                stdoutLines: [#"{"type":"error","message":"thread-store conflict: thread thread_expected already has an active writer"}"#]
            ),
            .init(stdoutLines: [#"{"id":"thread_expected","msg":{"type":"task_complete","last_message":"Done"}}"#]),
        ])
        let store = InMemoryStore()
        let record = SessionRecord(providerID: .codex, providerResumeToken: "thread_expected")
        let session = try makeSession(provider: .codex, record: record, backend: backend, store: store)

        let events = try await collectEvents(try await session.send("hello"))

        #expect(backend.launchedRequests.count == 2)
        #expect(backend.launchedRequests[0].arguments == backend.launchedRequests[1].arguments)
        #expect(backend.launchedRequests[0].arguments.contains("thread_expected"))
        #expect(events.compactMap(\.turnFailed).isEmpty)
        #expect(events.compactMap(\.turnCompleted).count == 1)
        #expect(try store.loadMessages(for: record.id).filter { $0.origin == .user }.count == 1)
        let statuses = events.compactMap { event -> String? in
            guard case .statusUpdate(let status) = event else { return nil }
            return status ?? "<cleared>"
        }
        #expect(statuses == [
            "Waiting for this Codex session to finish…",
            "<cleared>",
        ])
    }

    @Test func codexTurnFailedActiveThreadConflictWaitsAndRetriesSameSession() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(
                stdoutLines: [#"{"type":"turn.failed","error":{"message":"thread is already active in another process"}}"#]
            ),
            .init(
                stdoutLines: [#"{"type":"turn.failed","error":{"message":"thread is already active in another process"}}"#]
            ),
            .init(stdoutLines: [#"{"id":"thread_expected","msg":{"type":"task_complete","last_message":"Done"}}"#]),
        ])
        let store = InMemoryStore()
        let record = SessionRecord(providerID: .codex, providerResumeToken: "thread_expected")
        let session = try makeSession(provider: .codex, record: record, backend: backend, store: store)

        let events = try await collectEvents(try await session.send("hello"))

        #expect(backend.launchedRequests.count == 3)
        #expect(backend.launchedRequests[0].arguments == backend.launchedRequests[1].arguments)
        #expect(backend.launchedRequests[1].arguments == backend.launchedRequests[2].arguments)
        #expect(events.compactMap(\.turnFailed).isEmpty)
        #expect(events.compactMap(\.turnCompleted).count == 1)
        #expect(try store.loadMessages(for: record.id).filter { $0.origin == .user }.count == 1)
        let statuses = events.compactMap { event -> String? in
            guard case .statusUpdate(let status) = event else { return nil }
            return status ?? "<cleared>"
        }
        #expect(statuses == [
            "Waiting for this Codex session to finish…",
            "<cleared>",
        ])
    }

    @Test func manualCodexResumeConflictRetriesTheSameThread() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(onStdin: { data, process in
                let method = String(decoding: data, as: UTF8.self)
                    .split(separator: "\n")
                    .compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
                    .first?["method"]?.stringValue
                if method == "initialize" {
                    process.emitStdout(#"{"id":0,"result":{}}"#)
                } else if method == "thread/resume" {
                    process.emitStdout(#"{"id":1,"error":{"message":"thread-store conflict: thread thread_expected already has an active writer"}}"#)
                    process.finishStdout()
                }
            }),
            .init(onStdin: { data, process in
                let requests = String(decoding: data, as: UTF8.self)
                    .split(separator: "\n")
                    .compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
                for request in requests {
                    switch request["method"]?.stringValue {
                    case "initialize":
                        process.emitStdout(#"{"id":0,"result":{}}"#)
                    case "thread/resume":
                        process.emitStdout(#"{"id":1,"result":{"thread":{"id":"thread_expected"}}}"#)
                    case "turn/start":
                        process.emitStdout(#"{"id":2,"result":{"turn":{"id":"turn-1"}}}"#)
                        process.emitStdout(#"{"method":"turn/completed","params":{"turn":{"status":"completed"}}}"#)
                        process.finishStdout()
                    default:
                        break
                    }
                }
            }),
        ])
        let store = InMemoryStore()
        let record = SessionRecord(
            providerID: .codex,
            codexApprovalMode: .manual,
            providerResumeToken: "thread_expected"
        )
        let session = try makeSession(provider: .codex, record: record, backend: backend, store: store)

        let events = try await collectEvents(try await session.send("hello"))

        #expect(backend.launchedRequests.count == 2)
        #expect(backend.launchedRequests[0].arguments == ["app-server", "--stdio"])
        #expect(backend.launchedRequests[1].arguments == ["app-server", "--stdio"])
        #expect(events.compactMap(\.turnFailed).isEmpty)
        #expect(events.compactMap(\.turnCompleted).count == 1)
        #expect(try store.loadMessages(for: record.id).filter { $0.origin == .user }.count == 1)
    }

    @Test func cancellingWhileWaitingForCodexWriterStopsRetries() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(
                exitCode: 1,
                stderrLines: ["thread-store conflict: thread abc already has an active writer"]
            )
        ])
        let store = InMemoryStore()
        let record = SessionRecord(providerID: .codex, providerResumeToken: "thread_expected")
        let session = try makeSession(provider: .codex, record: record, backend: backend, store: store)
        let stream = try await session.send("hello")
        var events: [AgentEvent] = []

        for try await event in stream {
            events.append(event)
            if case .statusUpdate(.some(_)) = event {
                await session.cancelActiveTurn()
            }
        }

        #expect(backend.launchedRequests.count == 1)
        #expect(events.compactMap(\.turnCompleted).first?.stopReason == .cancelled)
        #expect(events.compactMap(\.turnFailed).isEmpty)
        #expect(try store.loadMessages(for: record.id).filter { $0.origin == .user }.count == 1)
        #expect(await session.record.status == .idle)
    }

    @Test func cleanExitWithoutResultFrameSynthesizesCompletion() async throws {
        let backend = ScriptedExecutionBackend(
            scripts: [.init(stdoutLines: [ClaudeFrames.assistantText])]
        )
        let session = try makeSession(backend: backend)

        let events = try await collectEvents(try await session.send("hello"))

        let summary = events.compactMap(\.turnCompleted).first
        #expect(summary?.stopReason == .completed)
        #expect(summary?.finalText == "Here is the answer")
    }

    @Test func backendLaunchFailureFailsTheTurn() async throws {
        let backend = ScriptedExecutionBackend(scripts: [])
        backend.launchError = .executionFailed(reason: "Executable \"claude\" was not found on PATH")
        let session = try makeSession(backend: backend)

        let events = try await collectEvents(try await session.send("hello"))

        let failure = events.compactMap(\.turnFailed).first
        guard case .executionFailed(let reason) = failure?.error else {
            Issue.record("expected executionFailed")
            return
        }
        #expect(reason.contains("not found"))
    }

    @Test func emptyPromptIsRejected() async throws {
        let session = try makeSession(backend: ScriptedExecutionBackend())
        do {
            _ = try await session.send("   ")
            Issue.record("expected an error for an empty prompt")
        } catch let error as SkynetError {
            guard case .executionFailed = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
    }

    @Test func persistenceFailureAbortsTheTurnCleanly() async throws {
        let backend = ScriptedExecutionBackend(
            scripts: [.init(stdoutLines: [ClaudeFrames.resultSuccess])]
        )
        let session = try makeSession(backend: backend, store: FailingPersistenceStore())

        do {
            _ = try await session.send("hello")
            Issue.record("expected the send to fail")
        } catch let error as SkynetError {
            guard case .persistenceFailure = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
        // Nothing was launched.
        #expect(backend.launchedRequests.isEmpty)
    }

    @Test func unknownOutputFramesAreForwardedNotDropped() async throws {
        let backend = ScriptedExecutionBackend(
            scripts: [
                .init(stdoutLines: [
                    ClaudeFrames.initialization,
                    #"{"type":"brand_new_frame","payload":{"x":1}}"#,
                    ClaudeFrames.resultSuccess,
                ])
            ]
        )
        let session = try makeSession(backend: backend)

        let events = try await collectEvents(try await session.send("hello"))

        #expect(events.contains { $0.unhandled?["type"]?.stringValue == "brand_new_frame" })
        #expect(events.compactMap(\.turnCompleted).first != nil)
    }

    // MARK: Attachments

    @Test func blobAttachmentsAreMaterializedInlineForTheCLI() async throws {
        let store = InMemoryStore()
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let reference = try store.storeBlob(imageData, mediaType: "image/png", fileName: "shot.png")
        let backend = ScriptedExecutionBackend(
            scripts: [.init(stdoutLines: [ClaudeFrames.resultSuccess])]
        )
        let session = try makeSession(backend: backend, store: store)
        let sessionID = await session.record.id

        let blobAttachment = ImageAttachment(payload: .blob(reference), fileName: "shot.png")
        _ = try await collectEvents(try await session.send("look at this", attachments: [blobAttachment]))

        // The CLI received inline base64, not a blob reference.
        let stdinText = backend.launchedProcesses[0].stdinWrites
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
        #expect(stdinText.contains("base64"))
        #expect(stdinText.contains(imageData.base64EncodedString()))
        #expect(!stdinText.contains("blobID"))

        // The transcript keeps the blob reference (small, deduplicated).
        let persisted = try store.loadMessages(for: sessionID)
        guard case .image(let storedAttachment) = persisted[0].content[1] else {
            Issue.record("expected an image block in the user message")
            return
        }
        guard case .blob(let storedReference) = storedAttachment.payload else {
            Issue.record("expected the persisted attachment to stay blob-backed")
            return
        }
        #expect(storedReference.blobID == reference.blobID)
    }

    // MARK: Concurrency control

    @Test func secondTurnWhileRunningIsRejectedThenCancellationEndsTheTurn() async throws {
        let (launched, launchContinuation) = AsyncStream<Void>.makeStream()
        // The stdin hook keeps the streams open, so this turn never ends
        // on its own.
        let backend = ScriptedExecutionBackend(
            scripts: [.init(stdoutLines: [ClaudeFrames.initialization], onStdin: { _, _ in
                launchContinuation.yield(())
                launchContinuation.finish()
            })]
        )
        let session = try makeSession(backend: backend)

        let firstStream = try await session.send("slow prompt")

        do {
            _ = try await session.send("impatient prompt")
            Issue.record("expected concurrent turn rejection")
        } catch let error as SkynetError {
            guard case .executionFailed(let reason) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(reason.contains("already running"))
        }

        // Cancellation before launch is valid, but would leave the first
        // scripted process queued for "try again". This case specifically
        // verifies cancellation of an already launched process.
        for await _ in launched { break }
        await session.cancelActiveTurn()
        let events = try await collectEvents(firstStream)
        #expect(events.compactMap(\.turnCompleted).first?.stopReason == .cancelled)

        // The session is usable again.
        backend.enqueue(.init(stdoutLines: [ClaudeFrames.resultSuccess]))
        let secondTurn = try await collectEvents(try await session.send("try again"))
        #expect(secondTurn.compactMap(\.turnCompleted).first?.stopReason == .completed)
    }
}
