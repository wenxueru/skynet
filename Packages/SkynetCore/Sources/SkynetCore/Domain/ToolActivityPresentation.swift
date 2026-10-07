import Foundation

/// A completed collaboration invocation is not a completed child agent.
public struct ToolActivityPresentation: Sendable {
    public enum Status: Sendable {
        case running, completed, failed, inactive
    }

    public let status: Status
    public let isAgentLifecycle: Bool
    public let detail: String
    private let reportedStatus: SubagentStatusReport.Status?

    public init(name: String, input: JSONValue, output: String?, isError: Bool,
                subagentStatus: SubagentStatusReport.Status? = nil) {
        isAgentLifecycle = name == "Subagent"
            && (input["agent_thread_id"]?.stringValue
                ?? input["agentThreadId"]?.stringValue) != nil
        reportedStatus = isAgentLifecycle ? subagentStatus : nil
        if let reportedStatus {
            switch reportedStatus {
            case .pendingInit, .running: status = .running
            case .errored, .notFound: status = .failed
            case .completed: status = .completed
            case .interrupted, .shutdown: status = .inactive
            }
        } else if output == nil {
            status = .running
        } else {
            status = isError ? .failed : .completed
        }
        detail = input["agent_path"]?.stringValue
            ?? input["agentPath"]?.stringValue
            ?? input["tool"]?.stringValue
            ?? name
    }

    public var statusLabel: String {
        if let reportedStatus { return reportedStatus.label }
        return switch (isAgentLifecycle, status) {
        case (true, .running): "Running"
        case (true, .completed): "Completed"
        case (true, .failed): "Failed"
        case (true, .inactive): "Stopped"
        case (false, .running): "Tool running"
        case (false, .completed): "Tool completed"
        case (false, .failed): "Tool failed"
        case (false, .inactive): "Tool stopped"
        }
    }
}
