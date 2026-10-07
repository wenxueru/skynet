import Foundation

/// The small JSON-RPC surface needed for human-reviewed or image Codex turns.
/// Text-only automatic review and legacy modes continue to use `codex exec`.
enum CodexAppServerBridge {
    /// `last` is one model response, not the whole turn. Use successive thread
    /// totals to include later responses; replayed/older snapshots add nothing.
    struct UsageTracker {
        private var previousTotal: TokenUsage?
        private var turnUsage = TokenUsage()

        mutating func observe(_ frame: JSONValue) -> TokenUsage? {
            guard let total = Self.decode(frame["params"]?["tokenUsage"]?["total"]),
                  let last = Self.decode(frame["params"]?["tokenUsage"]?["last"]) else { return nil }
            let delta: TokenUsage
            if let previousTotal {
                let old = Self.parts(previousTotal), new = Self.parts(total)
                guard zip(old, new).allSatisfy({ $0 <= $1 }), old != new else { return nil }
                delta = TokenUsage(
                    inputTokens: new[0] - old[0], cacheReadTokens: new[1] - old[1],
                    cacheWriteTokens: new[2] - old[2], outputTokens: new[3] - old[3],
                    reasoningTokens: new[4] - old[4]
                )
            } else { delta = last }
            previousTotal = total
            turnUsage += delta
            return turnUsage
        }

        private static func parts(_ usage: TokenUsage) -> [Int] {
            [usage.inputTokens, usage.cacheReadTokens, usage.cacheWriteTokens,
             usage.outputTokens, usage.reasoningTokens].map { $0 ?? 0 }
        }

        private static func decode(_ value: JSONValue?) -> TokenUsage? {
            guard let input = value?["inputTokens"]?.intValue,
                  let cached = value?["cachedInputTokens"]?.intValue,
                  let output = value?["outputTokens"]?.intValue,
                  let reasoning = value?["reasoningOutputTokens"]?.intValue else { return nil }
            let written = value?["cacheWriteInputTokens"]?.intValue ?? 0
            guard [input, cached, output, reasoning, written].allSatisfy({ $0 >= 0 }) else { return nil }
            return CodexEventParsing.usage(from: [
                "input_tokens": .number(String(input)), "cached_input_tokens": .number(String(cached)),
                "cache_write_input_tokens": .number(String(written)), "output_tokens": .number(String(output)),
                "reasoning_output_tokens": .number(String(reasoning)),
            ])
        }
    }

    static func initialization() throws -> Data {
        try encode([
            "id": 0,
            "method": "initialize",
            "params": ["clientInfo": ["name": "skynet", "title": "Skynet", "version": "1.0"]],
        ])
    }

    static func initializedNotification() throws -> Data {
        try encode(["method": "initialized", "params": [:]])
    }

    static func threadRequest(resumeToken: String?) throws -> Data {
        let threadRequest: JSONValue = resumeToken.map { token in
            ["id": 1, "method": "thread/resume", "params": ["threadId": .string(token)]]
        } ?? ["id": 1, "method": "thread/start", "params": [:]]
        return try encode(threadRequest)
    }

    static func archiveRequest(threadID: String, archived: Bool) throws -> Data {
        try encode([
            "id": 1,
            "method": .string(archived ? "thread/archive" : "thread/unarchive"),
            "params": ["threadId": .string(threadID)],
        ])
    }

    static func readThreadRequest(threadID: String) throws -> Data {
        try encode([
            "id": 1,
            "method": "thread/read",
            "params": ["threadId": .string(threadID), "includeTurns": false],
        ])
    }

    static func deleteRequest(threadID: String) throws -> Data {
        try encode([
            "id": 1,
            "method": "thread/delete",
            "params": ["threadId": .string(threadID)],
        ])
    }

    static func setNameRequest(threadID: String, name: String) throws -> Data {
        try encode([
            "id": 1,
            "method": "thread/name/set",
            "params": ["threadId": .string(threadID), "name": .string(name)],
        ])
    }

    static func forkRequest(threadID: String) throws -> Data {
        try encode([
            "id": 1,
            "method": "thread/fork",
            "params": ["threadId": .string(threadID)],
        ])
    }

    static func modelListRequest(cursor: String?) throws -> Data {
        var params: [String: JSONValue] = ["limit": 100, "includeHidden": false]
        if let cursor { params["cursor"] = .string(cursor) }
        return try encode(["id": 1, "method": "model/list", "params": .object(params)])
    }

    static func startTurn(
        threadID: String,
        turn: AgentTurnRequest,
        approvalMode: SessionRecord.CodexApprovalMode
    ) throws -> Data {
        var input: [JSONValue] = turn.prompt.isEmpty
            ? [] : [["type": "text", "text": .string(turn.prompt)]]
        for attachment in turn.attachments {
            guard case .inline(let data, let mediaType) = attachment.payload,
                  mediaType.hasPrefix("image/") else {
                throw SkynetError.attachmentUnsupported(
                    provider: "Codex",
                    reason: "Image attachment could not be encoded for the app server."
                )
            }
            input.append([
                "type": "image",
                "url": .string("data:\(mediaType);base64,\(data.base64EncodedString())"),
            ])
        }
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "clientUserMessageId": .string(turn.turnID.uuidString),
            "input": .array(input),
            "approvalPolicy": "on-request",
            // Resumed threads can retain auto_review from an earlier turn.
            "approvalsReviewer": approvalMode == .automatic ? "auto_review" : "user",
            "sandboxPolicy": ["type": "workspaceWrite"],
        ]
        if let cwd = turn.workingDirectory { params["cwd"] = .string(cwd) }
        if let model = turn.modelID { params["model"] = .string(model.rawValue) }
        if let effort = turn.effort { params["effort"] = .string(effort.rawValue) }
        return try encode(["id": 2, "method": "turn/start", "params": .object(params)])
    }

    static func approvalResponse(
        frame: JSONValue,
        decision: PermissionResponse.Decision
    ) throws -> Data {
        guard let id = frame["id"] else { throw SkynetError.executionFailed(reason: "Missing approval ID") }
        if frame["method"]?.stringValue == "item/permissions/requestApproval" {
            let granted = decision == .deny ? JSONValue.object([:])
                : frame["params"]?["permissions"] ?? .object([:])
            return try encode([
                "id": id,
                "result": [
                    "permissions": granted,
                    "scope": decision == .allowAlways ? "session" : "turn",
                ],
            ])
        }
        let value: String = switch decision {
        case .allow: "accept"
        case .allowAlways: "acceptForSession"
        case .deny: "decline"
        }
        return try encode(["id": id, "result": ["decision": .string(value)]])
    }

    static func unsupportedResponse(id: JSONValue) throws -> Data {
        try encode([
            "id": id,
            "error": ["code": -32601, "message": "Skynet cannot safely answer this request"],
        ])
    }

    static func decode(_ line: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }

    static func permissionRequest(_ frame: JSONValue, turn: AgentTurnRequest) -> PermissionRequest? {
        guard let method = frame["method"]?.stringValue,
              [
                "item/commandExecution/requestApproval",
                "item/fileChange/requestApproval",
                "item/permissions/requestApproval",
              ].contains(method),
              let id = frame["id"] else { return nil }
        let params = frame["params"]
        let command = params?["command"]?.stringValue
        let reason = params?["reason"]?.stringValue
        let cwd = params?["cwd"]?.stringValue
        let grantRoot = params?["grantRoot"]?.stringValue
        let isCommand = method.contains("commandExecution")
        let isPermissions = method.contains("permissions/requestApproval")
        let requested = isPermissions
            ? params?["permissions"].flatMap { try? JSONEncoder().encode($0) }
                .flatMap { String(data: $0, encoding: .utf8) }
            : nil
        let summary = [reason, command, grantRoot, cwd, requested]
            .compactMap { $0 }.joined(separator: "\n")
        return PermissionRequest(
            id: id.stringValue ?? id.intValue.map(String.init) ?? "unknown",
            sessionID: turn.sessionID,
            toolName: isCommand ? "Bash" : isPermissions ? "RequestPermissions" : "ApplyPatch",
            input: params ?? .null,
            summary: summary.isEmpty ? (isCommand ? "Approve command execution?" : "Approve file changes?") : summary
        )
    }

    static func events(_ frame: JSONValue, turn: AgentTurnRequest) -> [AgentEvent] {
        guard let method = frame["method"]?.stringValue else { return [] }
        let params = frame["params"]
        let context = TurnContext(
            turnID: turn.turnID,
            sessionID: turn.sessionID,
            providerID: turn.providerID,
            modelID: turn.modelID
        )
        switch method {
        case "item/agentMessage/delta":
            return params?["delta"]?.stringValue.map { [.textDelta($0)] } ?? []
        case "item/reasoning/summaryTextDelta":
            return params?["delta"]?.stringValue.map { [.thinkingDelta($0)] } ?? []
        case "item/started", "item/updated":
            guard let item = params?["item"], let id = item["id"]?.stringValue else { return [] }
            switch item["type"]?.stringValue {
            case "commandExecution":
                return [.toolCallStarted(ToolCall(
                    id: ToolCallID(id), name: "Bash",
                    input: ["command": item["command"] ?? .null]
                ))]
            case "fileChange":
                return [.toolCallStarted(ToolCall(
                    id: ToolCallID(id), name: "ApplyPatch",
                    input: ["changes": item["changes"] ?? .null]
                ))]
            case "collabAgentToolCall", "subagentToolCall":
                return [.toolCallStarted(ToolCall(
                    id: ToolCallID(id), name: "CodexAgent", input: item
                ))] + CodexEventParsing.reportedSubagentStatusEvents(item)
            case "subagentActivity", "SubAgentActivity", "subagent_activity":
                return subagentActivityEvents(item)
            default: return []
            }
        case "item/completed":
            guard let item = params?["item"] else { return [] }
            if isSubagentActivity(item) {
                return subagentActivityEvents(item)
            }
            if item["type"]?.stringValue == "agentMessage",
               let text = item["text"]?.stringValue, !text.isEmpty {
                return [.messageCompleted(Message(
                    origin: .agent,
                    content: [.text(text)],
                    modelID: turn.modelID,
                    providerID: turn.providerID
                ))]
            }
            if let id = item["id"]?.stringValue,
               ["commandExecution", "fileChange", "collabAgentToolCall", "subagentToolCall"]
                .contains(item["type"]?.stringValue ?? "") {
                let completed = AgentEvent.toolCallCompleted(ToolCallResult(
                    toolCallID: ToolCallID(id),
                    content: CodexEventParsing.renderToolOutput(item["aggregatedOutput"] ?? item["agentsStates"]),
                    isError: item["status"]?.stringValue != "completed"
                ))
                let isCollaboration = ["collabAgentToolCall", "subagentToolCall"]
                    .contains(item["type"]?.stringValue ?? "")
                return [completed] + (isCollaboration ? CodexEventParsing.reportedSubagentStatusEvents(item) : [])
            }
            return []
        case "turn/completed":
            let status = params?["turn"]?["status"]?.stringValue
            guard status == "completed" || status == "interrupted" else {
                let detail = params?["turn"]?["error"]?["message"]?.stringValue
                    ?? (status == "failed" ? "Codex turn failed"
                        : "Codex returned an invalid completion status: \(status ?? "missing")")
                return [.turnFailed(TurnFailure(context: context, error: .executionFailed(reason: detail)))]
            }
            return [.turnCompleted(TurnSummary(
                context: context,
                stopReason: status == "interrupted" ? .cancelled : .completed
            ))]
        case "error":
            let detail = params?["error"]?["message"]?.stringValue ?? "Codex reported an error"
            if params?["willRetry"]?.boolValue == true { return [.statusUpdate(detail)] }
            return [.turnFailed(TurnFailure(context: context, error: .executionFailed(reason: detail)))]
        default:
            return []
        }
    }

    private static func isSubagentActivity(_ item: JSONValue) -> Bool {
        ["subagentActivity", "SubAgentActivity", "subagent_activity"]
            .contains(item["type"]?.stringValue ?? "")
    }

    private static func subagentActivityEvents(_ item: JSONValue) -> [AgentEvent] {
        guard let agentID = item["agentThreadId"]?.stringValue
                ?? item["agent_thread_id"]?.stringValue else { return [] }
        let toolCallID = ToolCallID(agentID)

        switch item["kind"]?.stringValue?.lowercased() {
        case "started":
            return [.toolCallStarted(ToolCall(
                id: toolCallID, name: "Subagent", input: item
            ))]
        case "completed":
            return [.toolCallCompleted(ToolCallResult(
                toolCallID: toolCallID, content: "", isError: false
            ))]
        case "failed":
            return [.toolCallCompleted(ToolCallResult(
                toolCallID: toolCallID, content: "", isError: true
            ))]
        default:
            return []
        }
    }

    static func encode(_ value: JSONValue) throws -> Data {
        try JSONEncoder().encode(value) + Data([0x0A])
    }
}
