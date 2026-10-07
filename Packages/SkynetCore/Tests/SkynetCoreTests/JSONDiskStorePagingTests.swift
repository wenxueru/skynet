import Foundation
import SkynetCore
import Testing

@Suite("Transcript pagination")
struct JSONDiskStorePagingTests {
    @Test func correlatedCopyRepairReportsNegativeCountAndMetadataOnlyCursorInvalidation() throws {
        let directory = try TempDirectory()
        let store = try JSONDiskStore(rootURL: directory.url)
        let session = SessionID()
        let original = Message(origin: .user, content: [.text("original GIF")],
            createdAt: Date(timeIntervalSince1970: 100), providerID: .codex)
        let copy = Message(origin: .user, content: [.text("normalized PNG")],
            createdAt: Date(timeIntervalSince1970: 111), providerID: .codex)
        var canonical = original
        canonical.providerMessageID = copy.id
        try store.replaceMessages([original, copy], for: session)
        let repaired = try store.mergeMessagesResult([canonical], for: session)
        #expect(repaired.didRewrite)
        #expect(repaired.countDelta == -1)
        #expect(try store.loadMessages(for: session) == [canonical])
        let replay = try store.mergeMessagesResult([canonical], for: session)
        #expect(!replay.didRewrite && replay.countDelta == 0)

        try store.replaceMessages([original], for: session)
        let metadataOnly = try store.mergeMessagesResult([canonical], for: session)
        #expect(metadataOnly.didRewrite && metadataOnly.countDelta == 0)
        #expect(try store.loadMessages(for: session) == [canonical])

        let next = Message(origin: .agent, content: [.text("newer reply")], createdAt: Date(timeIntervalSince1970: 200))
        try store.replaceMessages([original, copy, next], for: session)
        let later = Message(origin: .agent, content: [.text("latest")], createdAt: Date(timeIntervalSince1970: 300))
        let netZero = try store.mergeMessagesResult([canonical, later], for: session)
        #expect(netZero.didRewrite && netZero.countDelta == 0)
        #expect(try store.loadMessages(for: session) == [canonical, next, later])
        let page = try store.loadMessagesPage(for: session, byteLimit: 1)
        #expect(page.messages == [later])
        #expect(page.olderCursor != nil)
    }
    @Test func repairsOlderToolHolesWithoutDroppingNewerMessagesOrDuplicatingImports() throws {
        let directory = try TempDirectory()
        let store = try JSONDiskStore(rootURL: directory.url)
        let id = SessionID()
        let prompt = Message(origin: .user, content: [.text("check")], createdAt: Date(timeIntervalSince1970: 100))
        let answer = Message(origin: .agent, content: [.text("done")], createdAt: Date(timeIntervalSince1970: 200))
        let tool = Message(origin: .agent, content: [.toolCall(ToolCall(id: ToolCallID("hole"), name: "Bash"))], createdAt: Date(timeIntervalSince1970: 120))
        let output = Message(origin: .toolResult, content: [.toolResult(toolCallID: ToolCallID("hole"), content: "OK", isError: false)], createdAt: Date(timeIntervalSince1970: 150))
        try store.replaceMessages([prompt, answer], for: id)
        #expect(try store.mergeMessages([prompt, tool, output, answer], for: id) == 2)
        #expect(try store.loadMessages(for: id) == [prompt, tool, output, answer])
        #expect(try store.mergeMessages([prompt, tool, output, answer], for: id) == 0)
        let latest = try store.loadMessagesPage(for: id, byteLimit: 1)
        #expect(latest.messages == [answer])
        let json = try SessionTranscriptExport.data(session: SessionRecord(id: id, providerID: .codex), messages: store.loadMessages(for: id), format: .json)
        let exported = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect((exported["messages"] as? [Any])?.count == 4)
    }

    @Test func concurrentImportAndLiveAppendKeepEveryMessage() async throws {
        let directory = try TempDirectory()
        let store = try JSONDiskStore(rootURL: directory.url)
        let otherStore = try JSONDiskStore(rootURL: directory.url)
        let id = SessionID()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                let message = Message(origin: .agent, content: [.text("record-\(index)")], createdAt: Date(timeIntervalSince1970: Double(index * 20)))
                group.addTask {
                    if index.isMultiple(of: 2) {
                        try store.appendMessage(message, to: id)
                    } else {
                        try otherStore.mergeMessages([message], for: id)
                    }
                }
            }
            try await group.waitForAll()
        }
        let messages = try store.loadMessages(for: id)
        #expect(messages.count == 30)
        #expect(Set(messages.map(\.plainText)).count == 30)
    }

    @Test func loadsTranscriptSlicesFromNewestToOldestWithoutGaps() throws {
        let directory = try TempDirectory()
        let store = try JSONDiskStore(rootURL: directory.url)
        let sessionID = SessionID()
        let expected = (0..<12).map { "message-\($0)-" + String(repeating: "x", count: 80) }
        let messages = expected.enumerated().map { index, text in
            Message(origin: .user, content: [.text(text)], createdAt: Date(timeIntervalSince1970: Double(index)))
        }
        try store.replaceMessages(messages, for: sessionID)

        var page = try store.loadMessagesPage(for: sessionID, byteLimit: 700)
        var pages = [page.messages]
        while let cursor = page.olderCursor {
            page = try store.loadMessagesPage(for: sessionID, before: cursor, byteLimit: 700)
            pages.append(page.messages)
        }

        #expect(pages.first?.last?.plainText == expected.last)
        #expect(pages.count > 1)
        #expect(pages.reversed().flatMap { $0 }.map(\.plainText) == expected)
    }

    @Test func oversizedMessageIsKeptAndOlderCursorStillProgresses() throws {
        let directory = try TempDirectory()
        let store = try JSONDiskStore(rootURL: directory.url)
        let sessionID = SessionID()
        let oversizedText = String(repeating: "x", count: 4_000)
        let pageSize = 512
        let messages = [
            Message(origin: .user, content: [.text("older")]),
            Message(origin: .agent, content: [.text(oversizedText)]),
        ]
        try store.replaceMessages(messages, for: sessionID)

        let oversizedPage = try store.loadMessagesPage(for: sessionID, byteLimit: pageSize)
        let cursor = try #require(oversizedPage.olderCursor)
        #expect(oversizedPage.messages.map(\.plainText) == [oversizedText])

        let olderPage = try store.loadMessagesPage(for: sessionID, before: cursor, byteLimit: pageSize)
        #expect(olderPage.messages.map(\.plainText) == ["older"])
        #expect(olderPage.olderCursor == nil)
    }
}
