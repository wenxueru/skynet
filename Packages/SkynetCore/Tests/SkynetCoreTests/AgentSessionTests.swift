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

    @Test(arguments: [SessionRecord.CodexApprovalMode.manual, .automatic])
    func codexImageUsesNativeAppServerInput(mode: SessionRecord.CodexApprovalMode) async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(onStdin: { data, process in
                let request = String(decoding: data, as: UTF8.self)
                let methods = request.split(separator: "\n").compactMap {
                    try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
                }.compactMap { $0["method"]?.stringValue }
                if methods.contains("thread/start") {
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

        _ = try await collectEvents(try await session.send(
            "", attachments: [ImageAttachment(data: Data([1, 2, 3]), mediaType: "image/png")]
        ))

        let request = try #require(backend.launchedProcesses.first?.stdinWrites.last)
        let frame = try JSONDecoder().decode(JSONValue.self, from: request)
        #expect(frame["method"]?.stringValue == "turn/start")
        #expect(frame["params"]?["input"]?[0]?["type"]?.stringValue == "image")
        #expect(frame["params"]?["input"]?[0]?["url"]?.stringValue
            == "data:image/png;base64,AQID")
        #expect(frame["params"]?["approvalsReviewer"]?.stringValue
            == (mode == .automatic ? "auto_review" : nil))
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
        let session = try makeSession(provider: .codex, backend: backend)

        let events = try await collectEvents(try await session.send("fix the bug"))

        let request = backend.launchedRequests[0]
        #expect(request.executable == "codex")
        #expect(request.arguments.first == "exec")
        #expect(request.arguments.contains("--json"))
        #expect(request.arguments.last == "fix the bug")
        #expect(!request.arguments.contains("--model"))

        #expect(events.compactMap(\.turnCompleted).first?.finalText == "fixed it")
        let record = await session.record
        #expect(record.status == .idle)
        #expect(record.providerResumeToken == "thread_1")
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

    @Test func manualCodexApprovalRoundTripsThroughAppServer() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(onStdin: { data, process in
                let input = String(decoding: data, as: UTF8.self)
                let methods = input.split(separator: "\n").compactMap {
                    try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
                }.compactMap { $0["method"]?.stringValue }
                if methods.contains("thread/start") {
                    process.emitStdout(#"{"id":1,"result":{"thread":{"id":"thread-manual"}}}"#)
                } else if methods.contains("turn/start") {
                    process.emitStdout(#"{"id":2,"result":{"turn":{"id":"turn-1"}}}"#)
                    process.emitStdout(#"{"id":42,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread-manual","turnId":"turn-1","itemId":"cmd-1","command":"date","reason":"Run a command"}}"#)
                } else if input.contains("decision") {
                    process.emitStdout(#"{"method":"item/completed","params":{"item":{"id":"answer-1","type":"agentMessage","text":"Done"}}}"#)
                    process.emitStdout(#"{"method":"turn/completed","params":{"turn":{"status":"completed"}}}"#)
                    process.finishStdout()
                }
            })
        ])
        let responder = ScriptedPermissionResponder(responses: [
            PermissionResponse(requestID: "", decision: .allow)
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
        #expect(responder.requests.count == 1)
        #expect(responder.requests.first?.summary.contains("date") == true)
        #expect(backend.launchedProcesses[0].stdinWrites.contains {
            String(decoding: $0, as: UTF8.self).contains("\"decision\":\"accept\"")
        })
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
        // The stdin hook keeps the streams open, so this turn never ends
        // on its own.
        let backend = ScriptedExecutionBackend(
            scripts: [.init(stdoutLines: [ClaudeFrames.initialization], onStdin: { _, _ in })]
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

        await session.cancelActiveTurn()
        let events = try await collectEvents(firstStream)
        #expect(events.compactMap(\.turnCompleted).first?.stopReason == .cancelled)

        // The session is usable again.
        backend.enqueue(.init(stdoutLines: [ClaudeFrames.resultSuccess]))
        let secondTurn = try await collectEvents(try await session.send("try again"))
        #expect(secondTurn.compactMap(\.turnCompleted).first?.stopReason == .completed)
    }
}
