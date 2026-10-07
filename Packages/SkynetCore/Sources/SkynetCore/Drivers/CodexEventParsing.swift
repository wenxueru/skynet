import Foundation

/// Shared normalization of Codex events, independent of exec or app-server transport.
enum CodexEventParsing {
    static func reportedSubagentStatusEvents(_ item: JSONValue) -> [AgentEvent] {
        guard case .object(let states) = item["agents_states"] ?? item["agentsStates"] else { return [] }
        return states.keys.sorted().map { id in
            let state = states[id]!
            let rawStatus = state["status"]?.stringValue
            let status = rawStatus.flatMap { raw -> SubagentStatusReport.Status? in
                switch raw {
                case "pendingInit": .pendingInit
                case "notFound": .notFound
                default: SubagentStatusReport.Status(rawValue: raw)
                }
            }
            guard !id.isEmpty, let status else {
                return .unhandledEvent(raw: ["agent_thread_id": .string(id), "state": state])
            }
            return .subagentStatusReported(SubagentStatusReport(
                agentThreadID: id, status: status, message: state["message"]?.stringValue
            ))
        }
    }

    /// Tool output is usually a string; some dialects send structured JSON.
    static func renderToolOutput(_ value: JSONValue?) -> String {
        switch value {
        case .none, .null:
            return ""
        case .string(let text):
            return text
        default:
            guard let data = try? JSONEncoder().encode(value) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func usage(from value: JSONValue?) -> TokenUsage? {
        guard let value else { return nil }
        // Codex input includes cache reads/writes; TokenUsage sums disjoint parts.
        let cached = value["cached_input_tokens"]?.intValue ?? 0
        let written = value["cache_write_input_tokens"]?.intValue ?? 0
        let usage = TokenUsage(
            inputTokens: value["input_tokens"]?.intValue.map { max(0, $0 - cached - written) },
            cacheReadTokens: value["cached_input_tokens"]?.intValue,
            cacheWriteTokens: value["cache_write_input_tokens"]?.intValue,
            outputTokens: value["output_tokens"]?.intValue,
            reasoningTokens: value["reasoning_output_tokens"]?.intValue
        )
        return usage.totalTokens == nil ? nil : usage
    }
}
