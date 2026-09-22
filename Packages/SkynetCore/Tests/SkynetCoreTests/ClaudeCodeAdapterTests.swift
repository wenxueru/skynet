import Foundation
import SkynetCore
import Testing

@Suite("Claude Code adapter")
struct ClaudeCodeAdapterTests {
    let adapter = ClaudeCodeAdapter()
    let provider = AgentProviderDescriptor.claudeCode

    func turn(
        prompt: String = "hello",
        modelID: ModelID? = nil,
        effort: ReasoningEffort? = nil,
        workingDirectory: String? = nil,
        resumeToken: String? = nil,
        attachments: [ImageAttachment] = []
    ) -> AgentTurnRequest {
        AgentTurnRequest(
            sessionID: SessionID(),
            providerID: .claudeCode,
            prompt: prompt,
            attachments: attachments,
            modelID: modelID,
            effort: effort,
            workingDirectory: workingDirectory,
            resumeToken: resumeToken
        )
    }

    // MARK: Argument construction

    @Test func baseArgumentsAlwaysRequestStreamJSONBothWays() throws {
        let arguments = try adapter.buildArguments(
            provider: provider,
            turn: turn(),
            permissions: .askEverything,
            interactivePermissions: false
        )
        #expect(arguments.starts(with: [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
        ]))
        #expect(!arguments.contains("--permission-prompt-tool"))
    }

    @Test func modelEffortAndResumeArePassedThrough() throws {
        let arguments = try adapter.buildArguments(
            provider: provider,
            turn: turn(
                modelID: ModelID("claude-opus-4-8"),
                effort: .high,
                resumeToken: "sess-42"
            ),
            permissions: .askEverything,
            interactivePermissions: false
        )
        let joined = arguments.joined(separator: " ")
        #expect(arguments.contains("--model"))
        #expect(arguments[arguments.index(after: arguments.firstIndex(of: "--model")!)] == "claude-opus-4-8")
        #expect(joined.contains("--effort high"))
        #expect(joined.contains("--resume sess-42"))
    }

    @Test func permissionRulesBecomeToolFlags() throws {
        let policy = PermissionPolicy(
            rules: [
                PermissionRule(effect: .allow, toolPattern: "Read"),
                PermissionRule(effect: .deny, toolPattern: "Bash", argumentPattern: "rm *"),
            ],
            defaultEffect: .ask
        )
        let arguments = try adapter.buildArguments(
            provider: provider,
            turn: turn(),
            permissions: policy,
            interactivePermissions: false
        )
        #expect(arguments.contains("Read"))
        #expect(arguments.contains("Bash(rm *)"))
        // One flag per pattern, never a comma-joined blob.
        #expect(arguments.filter { $0 == "--allowedTools" }.count == 1)
        #expect(arguments.filter { $0 == "--disallowedTools" }.count == 1)
    }

    @Test func allowByDefaultBypassesPermissions() throws {
        let arguments = try adapter.buildArguments(
            provider: provider,
            turn: turn(),
            permissions: PermissionPolicy(rules: [], defaultEffect: .allow),
            interactivePermissions: false
        )
        let joined = arguments.joined(separator: " ")
        #expect(joined.contains("--permission-mode bypassPermissions"))
    }

    @Test func askWithResponderEnablesTheStdioPermissionTool() throws {
        let arguments = try adapter.buildArguments(
            provider: provider,
            turn: turn(),
            permissions: .askEverything,
            interactivePermissions: true
        )
        let joined = arguments.joined(separator: " ")
        #expect(joined.contains("--permission-prompt-tool stdio"))
    }

    @Test func denyByDefaultAddsNoModeFlag() throws {
        let arguments = try adapter.buildArguments(
            provider: provider,
            turn: turn(),
            permissions: PermissionPolicy(rules: [], defaultEffect: .deny),
            interactivePermissions: false
        )
        #expect(!arguments.contains("--permission-mode"))
    }

    // MARK: Launch stdin

    @Test func launchStdinCarriesPromptAsAUserMessage() throws {
        let data = try adapter.launchStdin(provider: provider, turn: turn(prompt: "what time is it"))
        let frame = try JSONDecoder().decode(JSONValue.self, from: data!)
        #expect(frame["type"]?.stringValue == "user")
        #expect(frame["message"]?["role"]?.stringValue == "user")
        #expect(frame["message"]?["content"]?[0]?["text"]?.stringValue == "what time is it")
        // JSONL: exactly one trailing newline.
        #expect(data!.last == UInt8(ascii: "\n"))
        #expect(data!.dropLast().last != UInt8(ascii: "\n"))
    }

    @Test func launchStdinEncodesInlineImagesAsBase64Blocks() throws {
        let attachment = ImageAttachment(
            data: Data([0xFF, 0xD8, 0xFF]),
            mediaType: "image/jpeg",
            fileName: "cat.jpg"
        )
        let data = try adapter.launchStdin(
            provider: provider,
            turn: turn(prompt: "", attachments: [attachment])
        )
        let frame = try JSONDecoder().decode(JSONValue.self, from: data!)
        let blocks = frame["message"]?["content"]?.arrayValue ?? []
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"]?.stringValue == "image")
        #expect(blocks[0]["source"]?["media_type"]?.stringValue == "image/jpeg")
        #expect(blocks[0]["source"]?["data"]?.stringValue == "/9j/")
    }

    @Test func launchStdinRejectsBlobPayloads() {
        let reference = BlobReference(
            blobID: "ab",
            byteCount: 2,
            mediaType: "image/png"
        )
        let blobAttachment = ImageAttachment(payload: .blob(reference))
        #expect(throws: SkynetError.self) {
            _ = try adapter.launchStdin(
                provider: provider,
                turn: turn(attachments: [blobAttachment])
            )
        }
    }

    // MARK: Output parsing

    @Test func parsesInitFrameIntoSessionToken() {
        let line = #"{"type":"system","subtype":"init","session_id":"sess-123","model":"claude-opus-4-8"}"#
        let events = adapter.parseOutputLine(line, turn: turn())
        #expect(events.count == 1)
        #expect(events[0].sessionToken == "sess-123")
    }

    @Test func parsesAssistantMessageWithTextThinkingAndToolUse() {
        let line = """
        {"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"thinking","thinking":"let me look","signature":"sig"},{"type":"text","text":"Running ls"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":100,"cache_read_input_tokens":10,"cache_creation_input_tokens":5,"output_tokens":50}}}
        """
        let events = adapter.parseOutputLine(line, turn: turn(modelID: ModelID("claude-opus-4-8")))
        #expect(events.contains { $0.toolCallStarted?.name == "Bash" })
        #expect(events.contains { $0.usage?.outputTokens == 50 })

        let message = events.compactMap(\.message).first
        #expect(message?.origin == .agent)
        #expect(message?.modelID == ModelID("claude-opus-4-8"))
        #expect(message?.providerID == .claudeCode)
        #expect(message?.content.count == 3)
        #expect(message?.content[1].text == "Running ls")
        if case .toolCall(let call) = message?.content[2] {
            #expect(call.id == ToolCallID("toolu_1"))
            #expect(call.input["command"]?.stringValue == "ls")
        } else {
            Issue.record("expected a tool call block")
        }
        if case .thinking(let text, let signature) = message?.content[0] {
            #expect(text == "let me look")
            #expect(signature == "sig")
        } else {
            Issue.record("expected a thinking block")
        }
    }

    @Test func parsesToolResultsFromUserRoleFrames() {
        let line = """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"file1\\nfile2"}],"is_error":false}]}}
        """
        let events = adapter.parseOutputLine(line, turn: turn())
        let result = events.compactMap(\.toolCallCompleted).first
        #expect(result?.toolCallID == ToolCallID("toolu_1"))
        #expect(result?.content == "file1\nfile2")
        #expect(result?.isError == false)
        let message = events.compactMap(\.message).first
        #expect(message?.origin == .toolResult)
        if case .toolResult(let id, _, let isError) = message?.content.first {
            #expect(id == ToolCallID("toolu_1"))
            #expect(!isError)
        } else {
            Issue.record("expected a tool result block")
        }
    }

    @Test func parsesResultFrameIntoTurnCompletion() {
        let line = """
        {"type":"result","subtype":"success","result":"all done","session_id":"sess-123","duration_ms":1500,"usage":{"input_tokens":10,"output_tokens":5},"num_turns":1}
        """
        let turn = turn(modelID: ModelID("claude-opus-4-8"))
        let events = adapter.parseOutputLine(line, turn: turn)
        let summary = events.compactMap(\.turnCompleted).first
        #expect(summary?.stopReason == .completed)
        #expect(summary?.finalText == "all done")
        #expect(summary?.duration == 1.5)
        #expect(summary?.usage?.inputTokens == 10)
        #expect(summary?.context.turnID == turn.turnID)
        #expect(events.contains { $0.usage != nil })
    }

    @Test func errorResultSubtypesMapToStopped() {
        let line = #"{"type":"result","subtype":"error_max_turns","result":"gave up","session_id":"s"}"#
        let events = adapter.parseOutputLine(line, turn: turn())
        #expect(events.compactMap(\.turnCompleted).first?.stopReason == .stopped)
    }

    @Test func parsesControlRequestIntoPermissionRequest() {
        let line = """
        {"type":"control_request","request_id":"req-7","payload":{"type":"permission_request","tool_name":"Bash","input":{"command":"rm -rf /tmp/x"}}}
        """
        let events = adapter.parseOutputLine(line, turn: turn())
        let request = events.compactMap(\.permissionRequest).first
        #expect(request?.id == "req-7")
        #expect(request?.toolName == "Bash")
        #expect(request?.summary.contains("rm -rf /tmp/x") == true)
        #expect(request?.input["command"]?.stringValue == "rm -rf /tmp/x")
    }

    @Test func unknownFramesSurfaceAsUnhandled() {
        let line = #"{"type":"some_new_feature","data":[1,2,3]}"#
        let events = adapter.parseOutputLine(line, turn: turn())
        #expect(events.count == 1)
        #expect(events[0].unhandled?["type"]?.stringValue == "some_new_feature")
    }

    @Test func unparseableLinesAreFlaggedNotDropped() {
        let events = adapter.parseOutputLine("this is not json", turn: turn())
        #expect(events.count == 1)
        #expect(events[0].unhandled?["_skynetNote"]?.stringValue == "unparseable output line")
        #expect(events[0].unhandled?["line"]?.stringValue == "this is not json")
    }

    @Test func emptyAndWhitespaceLinesProduceNothing() {
        #expect(adapter.parseOutputLine("", turn: turn()).isEmpty)
        #expect(adapter.parseOutputLine("   \n ", turn: turn()).isEmpty)
    }

    // MARK: Permission responses

    @Test func encodesPermissionResponsesOnStdin() throws {
        let allow = PermissionResponse(requestID: "req-1", decision: .allow)
        let allowLine = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(adapter.permissionResponseStdin(allow)!.utf8)
        )
        #expect(allowLine["type"]?.stringValue == "control_response")
        #expect(allowLine["request_id"]?.stringValue == "req-1")
        #expect(allowLine["payload"]?["behavior"]?.stringValue == "allow")

        let allowEdited = PermissionResponse(
            requestID: "req-1",
            decision: .allow,
            updatedInput: ["command": "ls"]
        )
        let editedLine = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(adapter.permissionResponseStdin(allowEdited)!.utf8)
        )
        #expect(editedLine["payload"]?["updatedInput"]?["command"]?.stringValue == "ls")

        let deny = PermissionResponse(
            requestID: "req-2",
            decision: .deny,
            reason: "looks dangerous"
        )
        let denyLine = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(adapter.permissionResponseStdin(deny)!.utf8)
        )
        #expect(denyLine["payload"]?["behavior"]?.stringValue == "deny")
        #expect(denyLine["payload"]?["message"]?.stringValue == "looks dangerous")
    }
}
