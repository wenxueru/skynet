import Foundation
import SkynetCore
import Testing

@Suite("Transcript tool grouping")
struct TranscriptGroupingTests {
    @Test func mergesAdjacentCallsAndResultsAcrossMessages() throws {
        let first = ToolCall(id: ToolCallID("read-1"), name: "Read")
        let second = ToolCall(id: ToolCallID("shell-2"), name: "Bash")
        let messages = [
            Message(origin: .agent, content: [.text("Checking"), .toolCall(first)]),
            Message(origin: .toolResult, content: [
                .toolResult(toolCallID: first.id, content: "source", isError: false),
            ]),
            Message(origin: .agent, content: [.toolCall(second)]),
            Message(origin: .toolResult, content: [
                .toolResult(toolCallID: second.id, content: "passed", isError: false),
            ]),
            Message(origin: .agent, content: [.text("Done")]),
        ]

        let groups = TranscriptGrouping.groups(messages)
        #expect(groups.count == 3)
        if case .message(_, let firstMessage) = groups[0] {
            #expect(firstMessage.plainText == "Checking")
        } else { Issue.record("Expected opening prose") }
        if case .tools(_, let steps, _) = groups[1] {
            #expect(steps.map(\.call?.name) == ["Read", "Bash"])
            #expect(steps.map(\.result) == ["source", "passed"])
        } else { Issue.record("Expected one collapsed tool run") }
        if case .message(_, let lastMessage) = groups[2] {
            #expect(lastMessage.plainText == "Done")
        } else { Issue.record("Expected closing prose") }
    }

    @Test func unmatchedToolResultRemainsVisible() {
        let message = Message(origin: .toolResult, content: [
            .toolResult(toolCallID: ToolCallID("missing"), content: "error", isError: true),
        ])
        let groups = TranscriptGrouping.groups([message])
        if case .tools(_, let steps, _) = groups.first {
            #expect(steps.count == 1)
            #expect(steps[0].call == nil)
            #expect(steps[0].result == "error")
            #expect(steps[0].isError)
        } else { Issue.record("Expected a visible result-only step") }
    }

    @Test func keepsPlanningAndInteractiveToolsOutsideRuns() {
        let calls = [
            ToolCall(id: ToolCallID("read-1"), name: "Read"),
            ToolCall(id: ToolCallID("read-2"), name: "Read"),
            ToolCall(id: ToolCallID("plan"), name: "update_plan"),
            ToolCall(id: ToolCallID("read-3"), name: "Read"),
            ToolCall(id: ToolCallID("read-4"), name: "Read"),
        ]
        let groups = TranscriptGrouping.groups([
            Message(origin: .agent, content: calls.map(ContentBlock.toolCall)),
        ])
        #expect(groups.count == 3)
        if case .tools(_, let steps, _) = groups[1] {
            #expect(steps.map(\.call?.name) == ["update_plan"])
        } else { Issue.record("Expected a standalone planning tool") }
    }

    @Test func summaryClassifiesCommandsWithoutDisplayingTheirArguments() {
        let steps = [
            TranscriptToolStep(call: ToolCall(name: "Bash", input: ["command": "rg private_term src"])),
            TranscriptToolStep(call: ToolCall(name: "Read", input: ["file_path": "/secret/file"]),
                               result: "failed", isError: true),
        ]
        let summary = TranscriptRunSummary(steps: steps)
        #expect(summary.title == "Inspected files")
        #expect(summary.detail == "1 read · 1 search")
        #expect(summary.hasError)
        #expect(!summary.title.contains("private_term"))
        #expect(!summary.detail.contains("/secret/file"))
    }

    @Test func summaryUsesPluralCounts() {
        let steps = [
            TranscriptToolStep(call: ToolCall(name: "Bash")),
            TranscriptToolStep(call: ToolCall(name: "Bash")),
        ]
        #expect(TranscriptRunSummary(steps: steps).detail == "2 commands")
    }
}
