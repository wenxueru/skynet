import Foundation

/// Speaks the Claude Code CLI's headless protocol: `stream-json` in,
/// `stream-json` out.
///
/// Used for the built-in `claude-code` provider *and* for any
/// user-configured `.claudeCodeCompatible` wrapper — the wire protocol is
/// the same, only the executable differs.
///
/// Frame shapes handled (anything else lands in `.unhandledEvent`):
///
/// ```
/// {"type":"system","subtype":"init","session_id":"…"}
/// {"type":"assistant","message":{"role":"assistant","content":[…blocks…],"usage":{…}}}
/// {"type":"user","message":{"role":"user","content":[{"type":"tool_result",…}]}}
/// {"type":"result","subtype":"success","result":"…","usage":{…},"duration_ms":…}
/// {"type":"control_request","request_id":"…","payload":{…permission ask…}}
/// ```
public struct ClaudeCodeAdapter: ProviderProtocolAdapter {
    /// The canonical built-in kind; `.claudeCodeCompatible` wrappers reuse
    /// this adapter unchanged.
    public var kind: AgentProviderDescriptor.Kind { .claudeCode }

    public init() {}

    // MARK: ProviderProtocolAdapter

    public func buildArguments(
        provider: AgentProviderDescriptor,
        turn: AgentTurnRequest,
        permissions: PermissionPolicy,
        interactivePermissions: Bool
    ) throws -> [String] {
        if turn.forkOnResume && turn.resumeToken == nil {
            throw SkynetError.executionFailed(reason: "Claude fork requires a source session ID.")
        }
        var arguments: [String] = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            // stream-json output in print mode requires --verbose.
            "--verbose",
        ]
        if let modelID = turn.modelID {
            arguments += ["--model", modelID.rawValue]
        }
        if let effort = turn.effort {
            arguments += ["--effort", effort.rawValue]
        }
        if let resumeToken = turn.resumeToken {
            arguments += ["--resume", resumeToken]
            if turn.forkOnResume { arguments.append("--fork-session") }
        }
        // Permission policy → CLI flags. Rules pass through as native
        // Claude Code permission patterns; the default effect picks the
        // permission mode.
        for pattern in permissions.patternStrings(effect: .allow) {
            arguments += ["--allowedTools", pattern]
        }
        for pattern in permissions.patternStrings(effect: .deny) {
            arguments += ["--disallowedTools", pattern]
        }
        switch permissions.defaultEffect {
        case .allow:
            arguments += ["--permission-mode", "bypassPermissions"]
        case .deny:
            arguments += ["--permission-mode", "dontAsk"]
        case .ask:
            // Interactive asks only make sense when someone can answer.
            if interactivePermissions {
                arguments += ["--permission-prompt-tool", "stdio"]
            }
        }
        return arguments
    }

    public func launchStdin(
        provider: AgentProviderDescriptor,
        turn: AgentTurnRequest
    ) throws -> Data? {
        var blocks: [JSONValue] = []
        if !turn.prompt.isEmpty {
            blocks.append(["type": "text", "text": .string(turn.prompt)])
        }
        for attachment in turn.attachments {
            switch attachment.payload {
            case .inline(let data, let mediaType):
                blocks.append(
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": .string(mediaType),
                            "data": .string(data.base64EncodedString()),
                        ] as JSONValue,
                    ] as JSONValue
                )
            case .blob:
                throw SkynetError.attachmentUnsupported(
                    provider: provider.displayName,
                    reason: "blob attachments must be materialized to inline data before launch"
                )
            }
        }
        if blocks.isEmpty {
            blocks.append(["type": "text", "text": ""])
        }
        let frame: JSONValue = [
            "type": "user",
            "message": ["role": "user", "content": .array(blocks)],
        ]
        var data = try JSONEncoder().encode(frame)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    public func parseOutputLine(_ line: String, turn: AgentTurnRequest) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard
            let data = trimmed.data(using: .utf8),
            let frame = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return [Self.unparseable(trimmed)]
        }
        guard let type = frame["type"]?.stringValue else {
            return [.unhandledEvent(raw: frame)]
        }
        switch type {
        case "system":
            return parseSystem(frame)
        case "assistant":
            return parseAssistant(frame, turn: turn)
        case "user":
            return parseToolResults(frame, turn: turn)
        case "result":
            return parseResult(frame, turn: turn)
        case "control_request":
            return parseControlRequest(frame, turn: turn)
        default:
            return [.unhandledEvent(raw: frame)]
        }
    }

    public func permissionResponseStdin(_ response: PermissionResponse) -> String? {
        let payload: JSONValue
        switch response.decision {
        case .allow, .allowAlways:
            if let updatedInput = response.updatedInput {
                payload = ["behavior": "allow", "updatedInput": updatedInput]
            } else {
                payload = ["behavior": "allow"]
            }
        case .deny:
            payload = [
                "behavior": "deny",
                "message": .string(response.reason ?? "Denied in Skynet"),
            ]
        }
        let frame: JSONValue = [
            "type": "control_response",
            "request_id": .string(response.requestID),
            "payload": payload,
        ]
        guard let data = try? JSONEncoder().encode(frame) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Frame parsers

    private func parseSystem(_ frame: JSONValue) -> [AgentEvent] {
        guard
            frame["subtype"]?.stringValue == "init",
            let sessionID = frame["session_id"]?.stringValue
        else { return [.unhandledEvent(raw: frame)] }
        return [.sessionTokenReceived(providerSessionID: sessionID)]
    }

    private func parseAssistant(_ frame: JSONValue, turn: AgentTurnRequest) -> [AgentEvent] {
        guard let message = frame["message"] else {
            return [.unhandledEvent(raw: frame)]
        }
        var events: [AgentEvent] = []
        var blocks: [ContentBlock] = []
        for block in message["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text":
                if let text = block["text"]?.stringValue {
                    blocks.append(.text(text))
                }
            case "thinking":
                if let text = block["thinking"]?.stringValue {
                    blocks.append(
                        .thinking(text: text, signature: block["signature"]?.stringValue)
                    )
                }
            case "tool_use":
                if let name = block["name"]?.stringValue,
                    let callID = block["id"]?.stringValue
                {
                    let call = ToolCall(
                        id: ToolCallID(callID),
                        name: name,
                        input: block["input"] ?? .null
                    )
                    blocks.append(.toolCall(call))
                    events.append(.toolCallStarted(call))
                }
            default:
                continue
            }
        }
        if let usage = Self.usage(from: message["usage"]) {
            events.append(.usageReported(usage))
        }
        events.append(
            .messageCompleted(
                Message(
                    origin: .agent,
                    content: blocks,
                    createdAt: Date(),
                    modelID: turn.modelID,
                    providerID: turn.providerID
                )
            )
        )
        return events
    }

    private func parseToolResults(_ frame: JSONValue, turn: AgentTurnRequest) -> [AgentEvent] {
        guard let message = frame["message"] else {
            return [.unhandledEvent(raw: frame)]
        }
        var events: [AgentEvent] = []
        var blocks: [ContentBlock] = []
        for block in message["content"]?.arrayValue ?? [] {
            guard
                block["type"]?.stringValue == "tool_result",
                let callID = block["tool_use_id"]?.stringValue
            else { continue }
            let content = Self.renderToolResultContent(block["content"])
            let isError = block["is_error"]?.boolValue ?? false
            let result = ToolCallResult(
                toolCallID: ToolCallID(callID),
                content: content,
                isError: isError
            )
            blocks.append(
                .toolResult(toolCallID: result.toolCallID, content: content, isError: isError)
            )
            events.append(.toolCallCompleted(result))
        }
        if !blocks.isEmpty {
            events.append(
                .messageCompleted(
                    Message(
                        origin: .toolResult,
                        content: blocks,
                        createdAt: Date(),
                        providerID: turn.providerID
                    )
                )
            )
        }
        return events
    }

    private func parseResult(_ frame: JSONValue, turn: AgentTurnRequest) -> [AgentEvent] {
        let subtype = frame["subtype"]?.stringValue
        let stopReason: TurnSummary.StopReason
        switch subtype {
        case "success": stopReason = .completed
        default: stopReason = .stopped
        }
        let duration: TimeInterval?
        if let milliseconds = frame["duration_ms"]?.doubleValue {
            duration = milliseconds / 1000
        } else {
            duration = nil
        }
        let summary = TurnSummary(
            context: TurnContext(
                turnID: turn.turnID,
                sessionID: turn.sessionID,
                providerID: turn.providerID,
                modelID: turn.modelID
            ),
            stopReason: stopReason,
            finalText: frame["result"]?.stringValue,
            usage: Self.usage(from: frame["usage"]),
            duration: duration
        )
        var events: [AgentEvent] = []
        if let usage = summary.usage {
            events.append(.usageReported(usage))
        }
        events.append(.turnCompleted(summary))
        return events
    }

    private func parseControlRequest(_ frame: JSONValue, turn: AgentTurnRequest) -> [AgentEvent] {
        guard let requestID = frame["request_id"]?.stringValue else {
            return [.unhandledEvent(raw: frame)]
        }
        // Field names have drifted across CLI versions; accept the known
        // spellings rather than pinning to one.
        let payload = frame["payload"] ?? frame
        let toolName =
            payload["tool_name"]?.stringValue
            ?? payload["tool"]?.stringValue
            ?? "unknown-tool"
        let input =
            payload["input"]
            ?? payload["arguments"]
            ?? payload["input_schema"]
            ?? .null
        let call = ToolCall(id: ToolCallID(requestID), name: toolName, input: input)
        let summary =
            PermissionPolicy.primaryArgument(of: call)
                .map { "\(toolName): \($0)" }
                ?? toolName
        let request = PermissionRequest(
            id: requestID,
            sessionID: turn.sessionID,
            toolName: toolName,
            input: input,
            summary: summary
        )
        return [.permissionRequested(request)]
    }

    // MARK: - Helpers

    private static func usage(from value: JSONValue?) -> TokenUsage? {
        guard let value else { return nil }
        let usage = TokenUsage(
            inputTokens: value["input_tokens"]?.intValue,
            cacheReadTokens: value["cache_read_input_tokens"]?.intValue,
            cacheWriteTokens: value["cache_creation_input_tokens"]?.intValue,
            outputTokens: value["output_tokens"]?.intValue
        )
        return usage.totalTokens == nil ? nil : usage
    }

    /// `tool_result.content` is either a string or an array of content
    /// blocks; both render to plain text.
    private static func renderToolResultContent(_ content: JSONValue?) -> String {
        guard let content else { return "" }
        if let text = content.stringValue { return text }
        guard let blocks = content.arrayValue else { return "" }
        return blocks.compactMap { block -> String? in
            if block["type"]?.stringValue == "text" {
                return block["text"]?.stringValue
            }
            return nil
        }.joined(separator: "\n")
    }

    private static func unparseable(_ line: String) -> AgentEvent {
        .unhandledEvent(
            raw: ["_skynetNote": "unparseable output line", "line": .string(line)]
        )
    }
}
