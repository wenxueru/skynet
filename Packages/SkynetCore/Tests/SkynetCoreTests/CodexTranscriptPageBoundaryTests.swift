import Foundation
import SkynetCore
import Testing

@Suite("Codex transcript page boundaries")
struct CodexTranscriptPageBoundaryTests {
    @Test func keepsUserFragmentsWithTheirResponse() throws {
        let lines = [meta, response(), fragment("user_message"), fragment("item_started"), fragment("item_completed")]
        for index in 2..<lines.count {
            try check(lines, cutAt: index, expected: 1)
        }
    }

    @Test func doesNotCrossUnrelatedOrInvalidRecords() throws {
        for barrier in [
            fragment("item_completed", turn: "other"),
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}"#,
            #"{"type":"event_msg","payload":[1]}"#,
            #"{"type":"event_msg","payload":{"type":"item_started","item":[]}}"#,
            "not json"
        ] {
            try check([meta, response(), barrier, fragment("item_completed")], cutAt: 3, expected: 3)
        }
        try check([meta, response(turn: "other"), fragment("item_completed")], cutAt: 2, expected: 2)
        try check([meta, response(), #"{"type":"event_msg","payload":42}"#], cutAt: 2, expected: 2)
    }

    @Test func skipsTaggedInjectedContextButNotEarlierTurns() throws {
        let injected = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"context"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-1","content_item_kinds":["environment"]}}}"#
        try check([meta, response(), injected, fragment("item_completed")], cutAt: 3, expected: 1)
        try check([meta, injected, fragment("item_completed")], cutAt: 2, expected: 2)
        let malformed = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":42}]}}"#
        try check([meta, malformed, fragment("item_completed")], cutAt: 2, expected: 2)
    }

    @Test func honorsReadLimitIncludingOversizedPreviousLines() throws {
        let lines = [meta, response(text: String(repeating: "x", count: 70_000)), fragment("item_completed")]
        try check(lines, cutAt: 2, expected: 1)
        try check(lines, cutAt: 2, expected: 2, limit: 1024)
        try check(lines, cutAt: 2, expected: 2, limit: 0)
        try check(lines, cutAt: 0, expected: 0)
    }

    @Test func pageParsingRetainsClientIDAndLeavesOlderPageIntact() throws {
        let clientID = UUID()
        let lines = [meta, response(text: "older", turn: "older"), response(), fragment("item_completed", clientID: clientID)]
        let fixture = try fixture(lines)
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let handle = try FileHandle(forReadingFrom: fixture.url)
        defer { try? handle.close() }
        let adjusted = try CodexTranscriptPageBoundary.adjustedStart(in: handle, start: fixture.offsets[3], end: fixture.end)
        #expect(adjusted == fixture.offsets[2])
        let newest = fixture.url.deletingLastPathComponent().appendingPathComponent("newest.jsonl")
        let older = fixture.url.deletingLastPathComponent().appendingPathComponent("older.jsonl")
        try (meta + "\n" + lines[2...].joined(separator: "\n") + "\n").write(to: newest, atomically: true, encoding: .utf8)
        try (lines[..<2].joined(separator: "\n") + "\n").write(to: older, atomically: true, encoding: .utf8)
        let latest = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: newest))
        let previous = try #require(SessionHistoryDiscovery.parseCodexTranscript(at: older))
        #expect(latest.messages.map(\.id) == [MessageID(clientID)])
        #expect(previous.messages.count == 1)
        #expect(TranscriptMessageMerger.merge(previous.messages, latest.messages).count == 2)
    }

    private let meta = #"{"type":"session_meta","payload":{"id":"page-fixture"}}"#

    private func response(text: String = "request", turn: String = "turn-1") -> String {
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(text)"}],"internal_chat_message_metadata_passthrough":{"turn_id":"\#(turn)","content_item_kinds":["user.text"]}}}"#
    }

    private func fragment(_ type: String, turn: String = "turn-1", clientID: UUID = UUID()) -> String {
        #"{"type":"event_msg","payload":{"type":"\#(type)","turn_id":"\#(turn)","item":{"type":"UserMessage","client_id":"\#(clientID.uuidString)","content":[{"type":"text","text":"request"}]}}}"#
    }

    private func fixture(_ lines: [String]) throws -> (url: URL, offsets: [UInt64], end: UInt64) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fixture.jsonl")
        var offsets: [UInt64] = []
        var bytes = Data()
        for line in lines {
            offsets.append(UInt64(bytes.count))
            bytes.append(Data((line + "\n").utf8))
        }
        try bytes.write(to: url)
        return (url, offsets, UInt64(bytes.count))
    }

    private func check(_ lines: [String], cutAt: Int, expected: Int, limit: Int = CodexTranscriptPageBoundary.maximumPageBytes) throws {
        let fixture = try fixture(lines)
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let handle = try FileHandle(forReadingFrom: fixture.url)
        defer { try? handle.close() }
        let actual = try CodexTranscriptPageBoundary.adjustedStart(in: handle, start: fixture.offsets[cutAt], end: fixture.end, byteLimit: limit)
        #expect(actual == fixture.offsets[expected])
        // Execute only our generated fixture; compare the actual SSH helper with Swift.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import json,sys\n" + CodexTranscriptPageBoundary.pythonScript + "\nwith open(sys.argv[1],'rb') as source:\n    print(codex_page_start(source,int(sys.argv[2]),int(sys.argv[3]),int(sys.argv[4])))", fixture.url.path, String(fixture.offsets[cutAt]), String(fixture.end), String(limit)]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(UInt64(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) == actual)
    }
}
