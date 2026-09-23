import Foundation

/// The small JSON-RPC surface needed for a human-reviewed Codex turn.
/// Automatic review and legacy modes continue to use `codex exec`.
enum CodexAppServerBridge {
    static func initialization() throws -> Data {
        try encode([
            "id": 0,
            "method": "initialize",
            "params": ["clientInfo": ["name": "skynet", "title": "Skynet", "version": "1.0"]],
        ]) + encode(["method": "initialized", "params": [:]])
    }

    static func handshake(resumeToken: String?) throws -> Data {
        let threadRequest: JSONValue = resumeToken.map { token in
            ["id": 1, "method": "thread/resume", "params": ["threadId": .string(token)]]
        } ?? ["id": 1, "method": "thread/start", "params": [:]]
        return try initialization() + encode(threadRequest)
    }

    static func archiveRequest(threadID: String, archived: Bool) throws -> Data {
        try initialization() + encode([
            "id": 1,
            "method": .string(archived ? "thread/archive" : "thread/unarchive"),
            "params": ["threadId": .string(threadID)],
        ])
    }

    static func startTurn(threadID: String, turn: AgentTurnRequest) throws -> Data {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": [["type": "text", "text": .string(turn.prompt)]],
            "approvalPolicy": "on-request",
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
        case "item/started":
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
            default: return []
            }
        case "item/completed":
            guard let item = params?["item"] else { return [] }
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
               ["commandExecution", "fileChange"].contains(item["type"]?.stringValue ?? "") {
                return [.toolCallCompleted(ToolCallResult(
                    toolCallID: ToolCallID(id),
                    content: item["aggregatedOutput"]?.stringValue ?? "",
                    isError: item["status"]?.stringValue != "completed"
                ))]
            }
            return []
        case "turn/completed":
            let status = params?["turn"]?["status"]?.stringValue
            if status == "failed" {
                let detail = params?["turn"]?["error"]?["message"]?.stringValue ?? "Codex turn failed"
                return [.turnFailed(TurnFailure(context: context, error: .executionFailed(reason: detail)))]
            }
            return [.turnCompleted(TurnSummary(
                context: context,
                stopReason: status == "interrupted" ? .cancelled : .completed
            ))]
        case "error":
            let detail = params?["error"]?["message"]?.stringValue ?? "Codex reported an error"
            return [.turnFailed(TurnFailure(context: context, error: .executionFailed(reason: detail)))]
        default:
            return []
        }
    }

    private static func encode(_ value: JSONValue) throws -> Data {
        try JSONEncoder().encode(value) + Data([0x0A])
    }
}
