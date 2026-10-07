import Foundation
import SkynetCore
import Testing

@Suite("Incremental parent Codex subagent activity")
struct CodexSubagentActivityReaderTests {
    @Test func startsAtEOFAndReconcilesLifecycleByChildIdentity() async throws {
        try await fixture { url, append in
            try append(start("old") + activity("started", turn: "old"))
            let reader = try CodexSubagentActivityReader(url: url, parentThreadID: "parent", notBefore: date, chunkSize: 31)
            #expect(try await reader.readNext().reports.isEmpty)
            try append(start() + activity("started"))
            #expect(try await drain(reader) == [.init(agentThreadID: "child", status: .running, agentPath: "/root/qa")])
            try append(activity("completed") + end())
            #expect(try await drain(reader) == [.init(agentThreadID: "child", status: .completed, agentPath: "/root/qa")])
            #expect(try await reader.readNext().isFinished)
        }
    }

    @Test func newFileReadRejectsHistoricalForeignAndSubsequentTurns() async throws {
        try await fixture { url, append in
            try append(start("old", seconds: 1) + activity("started", turn: "old") + end("old"))
            try append(start() + activity("started", parent: "other") + activity("started", turn: "other"))
            try append(start("other") + activity("completed") + end() + start("next") + activity("failed", turn: "next"))
            let reader = try CodexSubagentActivityReader(url: url, parentThreadID: "parent", notBefore: date, startAtEnd: false)
            #expect(try await drain(reader).map(\.status) == [.completed])
            #expect(try await reader.readNext().isFinished)
        }
    }

    @Test func buffersSplitLinesAndDoesNotReplayACapturedPartialLine() async throws {
        try await fixture { url, append in
            let old = activity("started", turn: "old")
            let half = old.index(old.startIndex, offsetBy: old.count / 2)
            try append(String(old[..<half]))
            let reader = try CodexSubagentActivityReader(url: url, parentThreadID: "parent", notBefore: date)
            try append(String(old[half...]) + start())
            #expect(try await drain(reader).isEmpty)
            let line = activity("started")
            let split = line.index(line.startIndex, offsetBy: 75)
            try append(String(line[..<split]))
            #expect(try await drain(reader).isEmpty)
            try append(String(line[split...]))
            #expect(try await drain(reader).map(\.status) == [.running])
        }
    }

    @Test func preciseTimestampsExcludeASameSecondHistoricalForkTurn() async throws {
        try await fixture { url, append in
            try append(#"{"timestamp":"1970-01-01T00:01:39.900Z","type":"event_msg","payload":{"type":"task_started","turn_id":"old","started_at":99}}"# + "\n"
                       + activity("started", turn: "old") + end("old"))
            try append(#"{"timestamp":"1970-01-01T00:01:40.100Z","type":"event_msg","payload":{"type":"task_started","turn_id":"current","started_at":100}}"# + "\n"
                       + activity("started"))
            let reader = try CodexSubagentActivityReader(url: url, parentThreadID: "parent", notBefore: date, startAtEnd: false)
            #expect(try await drain(reader).map(\.status) == [.running])
        }
    }

    @Test func skipsOversizedMalformedAndUnknownItemsWithBoundedReads() async throws {
        try await fixture { url, append in
            let reader = try CodexSubagentActivityReader(url: url, parentThreadID: "parent", notBefore: date,
                                                       chunkSize: 64, maximumLineBytes: 512)
            try append(start() + String(repeating: "x", count: 5_000) + "\nnot json\n"
                       + activity("future_kind") + activity("failed") + activity("interrupted") + activity("shutdown"))
            #expect(try await drain(reader).map(\.status) == [.errored, .interrupted, .shutdown])
        }
    }

    @Test func truncationFinishesInsteadOfReplayingHistory() async throws {
        try await fixture { url, append in
            try append(String(repeating: "history\n", count: 100))
            let reader = try CodexSubagentActivityReader(url: url, parentThreadID: "parent", notBefore: date)
            try (start() + activity("started")).write(to: url, atomically: false, encoding: .utf8)
            let page = try await reader.readNext()
            #expect(page.isFinished && page.reports.isEmpty && !page.hasMore)
        }
    }

    @Test func abortedTurnAndMissingStartDoNotInventChildCompletion() async throws {
        try await fixture { url, append in
            let reader = try CodexSubagentActivityReader(url: url, parentThreadID: "parent", notBefore: date)
            try append(activity("completed") + start() + activity("started")
                       + #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"current"}}"# + "\n"
                       + activity("completed"))
            #expect(try await drain(reader).map(\.status) == [.running])
            #expect(try await reader.readNext().isFinished)
        }
    }

    private var date: Date { Date(timeIntervalSince1970: 100) }
    private func start(_ turn: String = "current", seconds: Int = 100) -> String {
        #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"\#(turn)","started_at":\#(seconds)}}"# + "\n"
    }
    private func end(_ turn: String = "current") -> String {
        #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"\#(turn)"}}"# + "\n"
    }
    private func activity(_ kind: String, turn: String = "current", parent: String = "parent") -> String {
        #"{"type":"event_msg","payload":{"type":"item_completed","thread_id":"\#(parent)","turn_id":"\#(turn)","item":{"type":"SubAgentActivity","kind":"\#(kind)","agent_thread_id":"child","agent_path":"/root/qa"}}}"# + "\n"
    }
    private func drain(_ reader: CodexSubagentActivityReader) async throws -> [SubagentStatusReport] {
        var result: [SubagentStatusReport] = []
        while true {
            let page = try await reader.readNext()
            result += page.reports
            if !page.hasMore { return result }
        }
    }
    private func fixture(_ body: (URL, (String) throws -> Void) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("own-parent.jsonl")
        try Data().write(to: url)
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        try await body(url) { text in
            try writer.seekToEnd()
            try writer.write(contentsOf: Data(text.utf8))
        }
    }
}
