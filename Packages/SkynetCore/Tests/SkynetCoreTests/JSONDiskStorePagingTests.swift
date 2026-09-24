import Foundation
import SkynetCore
import Testing

@Suite("Transcript pagination")
struct JSONDiskStorePagingTests {
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
