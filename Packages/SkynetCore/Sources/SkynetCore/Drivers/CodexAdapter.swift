import Foundation

/// Speaks the Codex CLI's `codex exec --json` protocol: prompt as a
/// positional argument, JSONL events on stdout.
///
/// The parser is deliberately tolerant: Codex has shipped (and may ship
/// again) more than one event dialect. Both the classic
/// `{"id":…,"msg":{"type":…}}` frames and the newer
/// `{"type":"item.*",…}` thread frames are understood; anything else lands
/// in `.unhandledEvent`.
///
/// Tool naming is normalized to Claude-Code-style names (`Bash`,
/// `ApplyPatch`, `mcp__server__tool`) so a single permission rule list
/// covers both providers.
public struct CodexAdapter: ProviderProtocolAdapter {
    public var kind: AgentProviderDescriptor.Kind { .codex }

    public init() {}

    // MARK: ProviderProtocolAdapter

    public func buildArguments(
        provider: AgentProviderDescriptor,
        turn: AgentTurnRequest,
        permissions: PermissionPolicy,
        interactivePermissions: Bool
    ) throws -> [String] {
        if !turn.attachments.isEmpty {
            throw SkynetError.attachmentUnsupported(
                provider: provider.displayName,
                reason:
                    "Codex only accepts image attachments as file paths (`-i`); inline or blob attachments cannot be sent."
            )
        }
        var arguments: [String] = ["exec", "--json"]
        if let workingDirectory = turn.workingDirectory, !workingDirectory.isEmpty {
            arguments += ["--cd", workingDirectory]
        }
        if let modelID = turn.modelID {
            arguments += ["--model", modelID.rawValue]
        }
        if let effort = turn.effort {
            arguments += ["-c", "model_reasoning_effort=\(effort.rawValue)"]
        }
        // Codex has no per-tool permission allowlist; only the coarse
        // default effect maps onto sandbox modes. `exec` is non-interactive
        // and never prompts.
        switch permissions.defaultEffect {
        case .deny:
            arguments += ["--sandbox", "read-only"]
        case .ask:
            arguments += ["--sandbox", "workspace-write"]
        case .allow:
            arguments += ["--full-auto"]
        }
        if let resumeToken = turn.resumeToken {
            arguments += ["resume", resumeToken]
        }
        arguments.append(turn.prompt)
        return arguments
    }

    public func launchStdin(
        provider: AgentProviderDescriptor,
        turn: AgentTurnRequest
    ) throws -> Data? {
        // Prompt travels as a positional argument; stdin is unused.
        nil
    }

    public func permissionResponseStdin(_ response: PermissionResponse) -> String? {
        // `codex exec` cannot ask questions; nothing to answer.
        nil
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
        if let message = frame["msg"] {
            return parseLegacyFrame(
                frame,
                message: message,
                turn: turn
            )
        }
        if let type = frame["type"]?.stringValue {
            return parseThreadFrame(frame, type: type, turn: turn)
        }
        return [.unhandledEvent(raw: frame)]
    }

    // MARK: - Legacy frames: {"id":…,"msg":{"type":…}}

    private func parseLegacyFrame(
        _ frame: JSONValue,
        message: JSONValue,
        turn: AgentTurnRequest
    ) -> [AgentEvent] {
        switch message["type"]?.stringValue {
        case "session_configured", "task_started":
            guard let threadID = frame["id"]?.stringValue else { return [] }
            return [.sessionTokenReceived(providerSessionID: threadID)]

        case "agent_message":
            guard let text = message["message"]?.stringValue else { return [] }
            return [
                .messageCompleted(
                    Message(
                        origin: .agent,
                        content: [.text(text)],
                        createdAt: Date(),
                        modelID: turn.modelID,
                        providerID: turn.providerID
                    )
                )
            ]

        case "agent_reasoning":
            guard let text = message["text"]?.stringValue else { return [] }
            return [.thinkingDelta(text)]

        case "exec_command_begin":
            guard let callID = message["call_id"]?.stringValue else { return [] }
            let call = ToolCall(
                id: ToolCallID(callID),
                name: "Bash",
                input: ["command": message["command"] ?? .null]
            )
            return [.toolCallStarted(call)]

        case "exec_command_end":
            guard let callID = message["call_id"]?.stringValue else { return [] }
            let content = [
                message["stdout"]?.stringValue,
                message["stderr"]?.stringValue,
            ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            let exitCode = message["exit_code"]?.intValue
            return [
                .toolCallCompleted(
                    ToolCallResult(
                        toolCallID: ToolCallID(callID),
                        content: content,
                        isError: (exitCode ?? 0) != 0
                    )
                )
            ]

        case "mcp_tool_call_begin":
            guard let callID = message["call_id"]?.stringValue else { return [] }
            let call = ToolCall(
                id: ToolCallID(callID),
                name: Self.mcpToolName(server: message["server"], tool: message["tool"]),
                input: message["arguments"] ?? message["invocation"] ?? .null
            )
            return [.toolCallStarted(call)]

        case "mcp_tool_call_end":
            guard let callID = message["call_id"]?.stringValue else { return [] }
            return [
                .toolCallCompleted(
                    ToolCallResult(
                        toolCallID: ToolCallID(callID),
                        content: Self.renderToolOutput(
                            message["output"] ?? message["result"]
                        ),
                        isError: false
                    )
                )
            ]

        case "patch_apply_begin":
            guard let callID = message["call_id"]?.stringValue else { return [] }
            return [
                .toolCallStarted(ToolCall(id: ToolCallID(callID), name: "ApplyPatch"))
            ]

        case "patch_apply_end":
            guard let callID = message["call_id"]?.stringValue else { return [] }
            let success = message["success"]?.boolValue ?? true
            return [
                .toolCallCompleted(
                    ToolCallResult(
                        toolCallID: ToolCallID(callID),
                        content: Self.renderToolOutput(
                            message["stdout"] ?? message["stderr"]
                        ),
                        isError: !success
                    )
                )
            ]

        case "token_count":
            let usage = TokenUsage(
                inputTokens: message["input_tokens"]?.intValue,
                cacheReadTokens: message["cached_input_tokens"]?.intValue,
                outputTokens: message["output_tokens"]?.intValue,
                reasoningTokens: message["reasoning_output_tokens"]?.intValue
            )
            return usage.totalTokens == nil ? [] : [.usageReported(usage)]

        case "task_complete":
            let summary = TurnSummary(
                context: TurnContext(
                    turnID: turn.turnID,
                    sessionID: turn.sessionID,
                    providerID: turn.providerID,
                    modelID: turn.modelID
                ),
                stopReason: .completed,
                finalText: message["last_message"]?.stringValue
            )
            return [.turnCompleted(summary)]

        case "error":
            let detail =
                message["message"]?.stringValue ?? String(describing: message)
            return [
                .turnFailed(
                    TurnFailure(
                        context: TurnContext(
                            turnID: turn.turnID,
                            sessionID: turn.sessionID,
                            providerID: turn.providerID,
                            modelID: turn.modelID
                        ),
                        error: .executionFailed(reason: detail)
                    )
                )
            ]

        default:
            return [.unhandledEvent(raw: frame)]
        }
    }

    // MARK: - Thread frames: {"type":"item.*"/"turn.*"/"thread.*"}

    private func parseThreadFrame(
        _ frame: JSONValue,
        type: String,
        turn: AgentTurnRequest
    ) -> [AgentEvent] {
        let context = TurnContext(
            turnID: turn.turnID,
            sessionID: turn.sessionID,
            providerID: turn.providerID,
            modelID: turn.modelID
        )
        switch type {
        case "thread.started":
            guard let threadID = frame["thread_id"]?.stringValue else { return [] }
            return [.sessionTokenReceived(providerSessionID: threadID)]

        case "item.started", "item.updated":
            guard let item = frame["item"] else { return [.unhandledEvent(raw: frame)] }
            return parseItemStart(item)

        case "item.completed":
            guard let item = frame["item"] else { return [.unhandledEvent(raw: frame)] }
            return parseItemCompletion(item, turn: turn, context: context)

        case "turn.completed":
            let usage = Self.usage(from: frame["usage"])
            return [
                .turnCompleted(
                    TurnSummary(
                        context: context,
                        stopReason: .completed,
                        finalText: frame["output"]?.stringValue,
                        usage: usage
                    )
                )
            ]

        case "turn.failed", "turn.aborted":
            let detail =
                frame["error"]?["message"]?.stringValue
                ?? frame["error"]?.stringValue
                ?? "Codex reported \(type)"
            return [.turnFailed(TurnFailure(context: context, error: .executionFailed(reason: detail)))]

        default:
            return [.unhandledEvent(raw: frame)]
        }
    }

    private func parseItemStart(_ item: JSONValue) -> [AgentEvent] {
        guard let itemID = item["id"]?.stringValue else { return [.unhandledEvent(raw: item)] }
        switch item["type"]?.stringValue {
        case "command_execution":
            return [
                .toolCallStarted(
                    ToolCall(
                        id: ToolCallID(itemID),
                        name: "Bash",
                        input: ["command": item["command"] ?? .null]
                    )
                )
            ]
        case "mcp_tool_call":
            return [
                .toolCallStarted(
                    ToolCall(
                        id: ToolCallID(itemID),
                        name: Self.mcpToolName(server: item["server"], tool: item["tool"]),
                        input: item["arguments"] ?? .null
                    )
                )
            ]
        case "file_change":
            return [
                .toolCallStarted(
                    ToolCall(
                        id: ToolCallID(itemID),
                        name: "ApplyPatch",
                        input: ["changes": item["changes"] ?? .null]
                    )
                )
            ]
        default:
            return [.unhandledEvent(raw: item)]
        }
    }

    private func parseItemCompletion(
        _ item: JSONValue,
        turn: AgentTurnRequest,
        context: TurnContext
    ) -> [AgentEvent] {
        guard let itemID = item["id"]?.stringValue else { return [.unhandledEvent(raw: item)] }
        switch item["type"]?.stringValue {
        case "agent_message":
            guard let text = item["text"]?.stringValue else { return [] }
            return [
                .messageCompleted(
                    Message(
                        origin: .agent,
                        content: [.text(text)],
                        createdAt: Date(),
                        modelID: turn.modelID,
                        providerID: turn.providerID
                    )
                )
            ]
        case "reasoning":
            guard let text = item["text"]?.stringValue else { return [] }
            return [.thinkingDelta(text)]
        case "command_execution":
            let content = item["aggregated_output"]?.stringValue
                ?? item["stdout"]?.stringValue
                ?? ""
            let exitCode = item["exit_code"]?.intValue
            return [
                .toolCallCompleted(
                    ToolCallResult(
                        toolCallID: ToolCallID(itemID),
                        content: content,
                        isError: (exitCode ?? 0) != 0
                    )
                )
            ]
        case "mcp_tool_call":
            return [
                .toolCallCompleted(
                    ToolCallResult(
                        toolCallID: ToolCallID(itemID),
                        content: Self.renderToolOutput(item["output"]),
                        isError: item["status"]?.stringValue == "failed"
                    )
                )
            ]
        case "file_change":
            return [
                .toolCallCompleted(
                    ToolCallResult(
                        toolCallID: ToolCallID(itemID),
                        content: Self.renderToolOutput(item),
                        isError: item["status"]?.stringValue == "failed"
                    )
                )
            ]
        case "error":
            return [
                .turnFailed(
                    TurnFailure(
                        context: context,
                        error: .executionFailed(
                            reason: item["message"]?.stringValue ?? "Codex item error"
                        )
                    )
                )
            ]
        default:
            return [.unhandledEvent(raw: item)]
        }
    }

    // MARK: - Helpers

    private static func mcpToolName(server: JSONValue?, tool: JSONValue?) -> String {
        switch (server?.stringValue, tool?.stringValue) {
        case (let server?, let tool?):
            return "mcp__\(server)__\(tool)"
        case (nil, let tool?):
            return tool
        default:
            return "mcp_tool"
        }
    }

    /// Tool output is usually a string; some dialects send structured JSON.
    private static func renderToolOutput(_ value: JSONValue?) -> String {
        switch value {
        case .none:
            return ""
        case .string(let text):
            return text
        case .null:
            return ""
        default:
            guard let data = try? JSONEncoder().encode(value) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private static func usage(from value: JSONValue?) -> TokenUsage? {
        guard let value else { return nil }
        let usage = TokenUsage(
            inputTokens: value["input_tokens"]?.intValue,
            cacheReadTokens: value["cached_input_tokens"]?.intValue,
            outputTokens: value["output_tokens"]?.intValue,
            reasoningTokens: value["reasoning_output_tokens"]?.intValue
        )
        return usage.totalTokens == nil ? nil : usage
    }

    private static func unparseable(_ line: String) -> AgentEvent {
        .unhandledEvent(
            raw: ["_skynetNote": "unparseable output line", "line": .string(line)]
        )
    }
}
