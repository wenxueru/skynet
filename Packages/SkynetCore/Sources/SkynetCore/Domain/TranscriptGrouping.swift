import Foundation

public struct TranscriptToolStep: Sendable, Equatable {
    public let call: ToolCall?
    public var result: String?
    public var isError: Bool

    public init(call: ToolCall? = nil, result: String? = nil, isError: Bool = false) {
        self.call = call
        self.result = result
        self.isError = isError
    }
}

public struct TranscriptRunSummary: Sendable, Equatable {
    public let title: String
    public let detail: String
    public let icon: String
    public let hasError: Bool

    public init(steps: [TranscriptToolStep]) {
        enum Kind: String, CaseIterable {
            case read = "read"
            case search = "search"
            case edit = "edit"
            case command = "command"
            case web = "web"
            case other = "other"
        }

        func kind(_ call: ToolCall?) -> Kind {
            guard let call else { return .other }
            let name = call.name.lowercased()
            if name.contains("search") || name.contains("grep") || name.contains("glob") {
                return .search
            }
            if name.contains("read") || name.contains("view") || name == "ls" {
                return .read
            }
            if name.contains("edit") || name.contains("write") || name.contains("patch") {
                return .edit
            }
            if name.contains("web") || name.contains("browse") { return .web }
            if name.contains("bash") || name.contains("exec") || name.contains("shell") {
                let command = (call.input["command"]?.stringValue
                    ?? call.input["cmd"]?.stringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if ["rg ", "grep ", "findstr "].contains(where: command.hasPrefix) {
                    return .search
                }
                if ["cat ", "sed -n ", "ls ", "head ", "tail "].contains(where: command.hasPrefix) {
                    return .read
                }
                return .command
            }
            return .other
        }

        let kinds = steps.map { kind($0.call) }
        let counts = Dictionary(grouping: kinds, by: { $0 }).mapValues(\.count)
        var primary: Kind = .other
        var highestCount = 0
        for candidate in Kind.allCases where counts[candidate, default: 0] > highestCount {
            primary = candidate
            highestCount = counts[candidate, default: 0]
        }
        let presentation: (String, String) = switch primary {
        case .read: ("Inspected files", "doc.text.magnifyingglass")
        case .search: ("Searched content", "magnifyingglass")
        case .edit: ("Edited files", "pencil")
        case .command: ("Ran commands", "terminal")
        case .web: ("Browsed web", "globe")
        case .other: ("Used tools", "wrench.and.screwdriver")
        }
        title = presentation.0
        icon = presentation.1
        hasError = steps.contains(where: \.isError)
        detail = Kind.allCases.compactMap { kind in
            let count = counts[kind, default: 0]
            return count == 0 ? nil : "\(count) \(kind.rawValue)\(count == 1 ? "" : "s")"
        }.joined(separator: " · ")
    }
}

public enum TranscriptGroup: Sendable, Identifiable {
    case message(id: String, message: Message)
    case tools(id: String, steps: [TranscriptToolStep], collapseSingle: Bool)

    public var id: String {
        switch self {
        case .message(let id, _), .tools(let id, _, _): id
        }
    }
}

/// Coalesces adjacent tool calls and their results without changing the stored transcript.
public enum TranscriptGrouping {
    private enum ToolFamily: Equatable {
        case regular
        case exploration
        case standalone
    }

    private static let standaloneNames: Set<String> = [
        "TodoWrite", "update_plan", "ExitPlanMode", "exit_plan_mode", "CodexReasoning",
        "Task", "Agent", "CodexAgent", "TeamCreate", "TeamDelete", "SendMessage",
        "AgyTaskLog", "Skill", "spawn_agent", "send_input", "send_message",
        "resume_agent", "followup_task", "wait_agent", "close_agent",
        "interrupt_agent", "list_agents", "CodexPermission", "AskUserQuestion",
        "request_user_input", "mcp__codex_app__request_user_input",
    ]

    public static func groups(_ messages: [Message]) -> [TranscriptGroup] {
        var groups: [TranscriptGroup] = []
        var steps: [TranscriptToolStep] = []
        var toolGroupID: String?
        var toolFamily: ToolFamily?

        func flushTools() {
            guard let toolGroupID, !steps.isEmpty else { return }
            groups.append(.tools(
                id: toolGroupID, steps: steps, collapseSingle: toolFamily == .exploration
            ))
            steps.removeAll(keepingCapacity: true)
            toolFamily = nil
        }

        for message in messages {
            var prose: [ContentBlock] = []
            var proseStart = 0

            func flushProse() {
                guard !prose.isEmpty else { return }
                var partial = message
                partial.content = prose
                groups.append(.message(
                    id: "\(message.id.description):\(proseStart)", message: partial
                ))
                prose.removeAll(keepingCapacity: true)
            }

            for (index, block) in message.content.enumerated() {
                switch block {
                case .toolCall(let call):
                    flushProse()
                    let family = family(for: call)
                    if toolFamily != family || family == .standalone { flushTools() }
                    if steps.isEmpty { toolGroupID = "\(message.id.description):\(index):tools" }
                    toolFamily = family
                    steps.append(TranscriptToolStep(call: call))
                case .toolResult(let id, let content, let isError):
                    flushProse()
                    if steps.isEmpty {
                        toolGroupID = "\(message.id.description):\(index):tools"
                        toolFamily = .standalone
                    }
                    if let match = steps.lastIndex(where: { $0.call?.id == id && $0.result == nil }) {
                        steps[match].result = content
                        steps[match].isError = isError
                    } else {
                        steps.append(TranscriptToolStep(result: content, isError: isError))
                    }
                default:
                    flushTools()
                    if prose.isEmpty { proseStart = index }
                    prose.append(block)
                }
            }
            flushProse()
        }
        flushTools()
        return groups
    }

    private static func family(for call: ToolCall) -> ToolFamily {
        let name = call.name
        if standaloneNames.contains(name) || name.lowercased().contains("subagent")
            || call.input["permission"]?["status"]?.stringValue == "pending" {
            return .standalone
        }
        let source = call.input["command_source"]?.stringValue
            ?? call.input["commandSource"]?.stringValue
        if name == "CodexBash" && source?.lowercased() == "usershell" {
            return .standalone
        }
        let actions = call.input["command_actions"]?.arrayValue
            ?? call.input["commandActions"]?.arrayValue ?? []
        if name == "CodexBash" && !actions.isEmpty && actions.allSatisfy({
            ["read", "listFiles", "search"].contains($0["type"]?.stringValue ?? "")
        }) {
            return .exploration
        }
        return .regular
    }
}
