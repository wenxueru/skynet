// The runner inserts the actual AppModel.LiveTool and apply implementation.
// This minimal host never opens a store, session, provider, or app window.
@MainActor
final class AppModel {
    var selectedSessionID: SessionID?
    var messages: [Message] = []
    var liveText = ""
    var liveThinking = ""
    var liveStatusText: String?
    var errorMessage: String?
    var liveTools: [LiveTool] = []
    // PRODUCTION_MEMBERS

    func consume(_ event: AgentEvent, sessionID: SessionID) {
        apply(event, sessionID: sessionID)
    }
}

@main
enum SubagentActivityRegression {
    @MainActor
    static func main() {
        do { try verify() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    @MainActor
    private static func verify() throws {
        let model = AppModel()
        let sessionID = SessionID()
        model.selectedSessionID = sessionID
        func report(_ id: String, _ status: SubagentStatusReport.Status, _ message: String? = nil) {
            model.consume(.subagentStatusReported(.init(agentThreadID: id, status: status, message: message)),
                        sessionID: sessionID)
        }
        func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw FixtureFailure.mismatch(label) }
            print("PASS: \(label)")
        }
        func presentation(_ row: AppModel.LiveTool) -> ToolActivityPresentation {
            .init(name: row.name, input: row.input, output: row.output, isError: row.isError,
                  subagentStatus: row.subagentStatus)
        }

        report("child-a", .running)
        try require(model.liveTools.count == 1 && model.liveTools[0].output == nil,
                    "running child creates one live row")
        report("child-a", .completed, "exact child result")
        try require(model.liveTools.count == 1 && model.liveTools[0].output == "exact child result"
                    && presentation(model.liveTools[0]).statusLabel == "Completed",
                    "completion replaces the same child row")
        report("child-a", .running)
        try require(model.liveTools.count == 1 && model.liveTools[0].output == nil,
                    "later running report clears stale completion")
        report("child-a", .shutdown)
        try require(presentation(model.liveTools[0]).status == .inactive
                    && presentation(model.liveTools[0]).statusLabel == "Stopped",
                    "shutdown is inactive, not successful completion")
        report("child-b", .errored, "owned fixture failure")
        try require(model.liveTools.count == 2 && model.liveTools[1].isError
                    && presentation(model.liveTools[1]).statusLabel == "Failed",
                    "separate failed child has a separate truthful row")
        model.consume(.toolCallStarted(.init(id: ToolCallID("child-a"), name: "CodexAgent:wait",
                                          input: .object([:]))), sessionID: sessionID)
        model.consume(.toolCallCompleted(.init(toolCallID: ToolCallID("child-a"),
                                            content: "invocation finished", isError: false)),
                    sessionID: sessionID)
        try require(model.liveTools.count == 3 && model.liveTools[0].subagentStatus == .shutdown,
                    "tool completion cannot overwrite child lifecycle")
        try require(model.messages.isEmpty, "status snapshots do not fabricate transcript messages")
        model.consume(.subagentStatusReported(.init(agentThreadID: "child-a", status: .completed,
                                                  agentPath: "/root/own-fixture")), sessionID: sessionID)
        try require(model.liveTools.count == 3
                    && model.liveTools[0].input["agent_path"]?.stringValue == "/root/own-fixture",
                    "parent rollout and stdout reports share a row and preserve the child path")
        report("child-a", .running)
        try require(model.liveTools[0].input["agent_path"]?.stringValue == "/root/own-fixture",
                    "a subsequent path-less state retains the known child label")
        model.consume(.turnCompleted(.init(context: .init(sessionID: sessionID, providerID: .codex),
                                        stopReason: .cancelled)), sessionID: sessionID)
        try require(model.liveTools.isEmpty, "cancelled turn clears current activity")
    }

    private enum FixtureFailure: Error { case mismatch(String) }
}
