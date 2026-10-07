import SkynetCore
import Testing

@Suite("Reported activity semantics")
struct ToolActivityPresentationTests {
    @Test(arguments: SubagentStatusReport.Status.allCases)
    func explicitReportedStateDoesNotDependOnToolOutput(_ status: SubagentStatusReport.Status) {
        let activity = ToolActivityPresentation(name: "Subagent",
            input: ["agent_thread_id": "child"], output: "tool finished", isError: false,
            subagentStatus: status)
        #expect(activity.statusLabel == status.label)
        #expect(activity.isAgentLifecycle)
        #expect((activity.status == .running) == status.isActive)
        #expect((activity.status == .failed) == status.isError)
        #expect((activity.status == .completed) == (status == .completed))
    }
    @Test(arguments: ["wait", "spawn_agent"])
    func collaborationCompletionDoesNotClaimChildCompleted(_ tool: String) {
        let activity = ToolActivityPresentation(
            name: "CodexAgent",
            input: ["tool": .string(tool), "receiver_thread_ids": [], "agents_states": [:]],
            output: "{}", isError: false
        )
        #expect(!activity.isAgentLifecycle)
        #expect(activity.statusLabel == "Tool completed")
        #expect(activity.detail == tool)
    }

    @Test(arguments: ["agent_thread_id", "agentThreadId"])
    func explicitChildLifecycleUsesAgentIdentity(_ key: String) {
        let input: JSONValue = .object([
            key: .string("child"), "agent_path": .string("/root/qa")
        ])
        let running = ToolActivityPresentation(name: "Subagent", input: input, output: nil, isError: false)
        let done = ToolActivityPresentation(name: "Subagent", input: input, output: "", isError: false)
        let failed = ToolActivityPresentation(name: "Subagent", input: input, output: "", isError: true)
        #expect(running.isAgentLifecycle)
        #expect(running.statusLabel == "Running")
        #expect(done.statusLabel == "Completed")
        #expect(failed.statusLabel == "Failed")
        #expect(done.detail == "/root/qa")
    }

    @Test func failureIsNotPresentedAsDoneAndMissingIdentityIsNotAChild() {
        let activity = ToolActivityPresentation(name: "Subagent", input: [:], output: "denied", isError: true)
        #expect(!activity.isAgentLifecycle)
        #expect(activity.statusLabel == "Tool failed")
        let pending = ToolActivityPresentation(name: "Bash", input: [:], output: nil, isError: false)
        #expect(pending.statusLabel == "Tool running")
        let pendingError = ToolActivityPresentation(name: "Bash", input: [:], output: nil, isError: true)
        #expect(pendingError.statusLabel == "Tool running")
    }
}
