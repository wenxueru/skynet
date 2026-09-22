import XCTest
@testable import Skynet

final class TranscriptSearchTests: XCTestCase {
    private func item(_ id: String, _ text: String) -> TranscriptItem {
        .assistantMessage(AssistantMessage(id: TranscriptItemID(id), text: text))
    }

    private let items: [TranscriptItem] = [
        // Two matches in one item, one in the next.
        TranscriptItem.userMessage(
            UserMessage(id: TranscriptItemID("u1"), text: "fix the flaky test")
        ),
        TranscriptItem.assistantMessage(
            AssistantMessage(id: TranscriptItemID("a1"), text: "Which test fails?")
        ),
        TranscriptItem.toolCall(
            ToolCallRecord(
                id: TranscriptItemID("t1"),
                title: "npm test",
                arguments: "npm test -- --filter test",
                output: "Tests: 1 failed"
            )
        ),
        TranscriptItem.systemNotice(
            SystemNotice(id: TranscriptItemID("n1"), text: "Relay reconnected")
        ),
    ]

    func testInactiveSearchReturnsEverything() {
        let search = TranscriptSearch(query: "   ")
        XCTAssertFalse(search.isActive)
        XCTAssertEqual(search.apply(to: items).count, items.count)
        XCTAssertEqual(search.matchCount(in: items), 0)
        XCTAssertTrue(search.highlightRanges(in: "any text").isEmpty)
    }

    func testApplyFiltersItemsWithMatches() {
        let search = TranscriptSearch(query: "test")
        let filtered = search.apply(to: items)
        XCTAssertEqual(
            filtered.map(\.id),
            [TranscriptItemID("u1"), TranscriptItemID("a1"), TranscriptItemID("t1")]
        )
    }

    func testMatchCountCountsEveryOccurrence() {
        let search = TranscriptSearch(query: "test")
        // u1 "flaky test" (1) + a1 "Which test fails?" (1)
        // + t1: title (1), arguments (2), output "Tests" (1)
        XCTAssertEqual(search.matchCount(in: items), 6)
    }

    func testSearchIsCaseAndDiacriticInsensitive() {
        let search = TranscriptSearch(query: "RELAY réconnected")
        let filtered = search.apply(to: items)
        XCTAssertEqual(filtered.map(\.id), [TranscriptItemID("n1")])
    }

    func testToolCallSearchSpansTitleArgumentsAndOutput() {
        let search = TranscriptSearch(query: "failed")
        let filtered = search.apply(to: items)
        XCTAssertEqual(filtered.map(\.id), [TranscriptItemID("t1")])
        XCTAssertEqual(search.highlightRanges(in: "Tests: 1 failed").count, 1)
    }

    func testTextMatchFinderFindsNonOverlappingRanges() {
        let ranges = TextMatchFinder.ranges(of: "aa", in: "aaaa")
        XCTAssertEqual(ranges.count, 2, "matches must not overlap")
        XCTAssertTrue(TextMatchFinder.ranges(of: "", in: "anything").isEmpty)
        XCTAssertTrue(TextMatchFinder.ranges(of: "x", in: "").isEmpty)
    }

    func testTextMatchFinderIsCaseInsensitive() {
        let haystack = "Run the Suite — SUITE runner"
        let ranges = TextMatchFinder.ranges(of: "suite", in: haystack)
        XCTAssertEqual(ranges.count, 2)
        for range in ranges {
            XCTAssertEqual(haystack[range].lowercased(), "suite")
        }
    }
}

final class LongMessagePolicyTests: XCTestCase {
    private let policy = LongMessagePolicy.default

    func testShortMessagesDoNotCollapse() {
        XCTAssertFalse(policy.shouldCollapse("hello"))
        XCTAssertFalse(policy.shouldCollapse(""))
    }

    func testLongTextCollapsesAtCharacterLimit() {
        let short = String(repeating: "a", count: policy.characterLimit - 1)
        let atLimit = String(repeating: "a", count: policy.characterLimit)
        XCTAssertFalse(policy.shouldCollapse(short))
        XCTAssertTrue(policy.shouldCollapse(atLimit))
    }

    func testManyLinesCollapseEvenUnderCharacterLimit() {
        let fifteenLines = Array(repeating: "line", count: policy.lineLimit - 1)
            .joined(separator: "\n")
        let sixteenLines = Array(repeating: "line", count: policy.lineLimit)
            .joined(separator: "\n")
        XCTAssertFalse(policy.shouldCollapse(fifteenLines))
        XCTAssertTrue(policy.shouldCollapse(sixteenLines))
    }

    func testPreviewCutsToCharacterLimitAndTrims() {
        let text = "  " + String(repeating: "x", count: policy.characterLimit + 40)
        let preview = policy.preview(of: text)
        XCTAssertEqual(preview, String(repeating: "x", count: policy.characterLimit - 2))
    }

    func testPreviewReturnsShortTextUntouched() {
        XCTAssertEqual(policy.preview(of: "short text"), "short text")
    }

    func testCustomPolicy() {
        let tight = LongMessagePolicy(characterLimit: 10, lineLimit: 3)
        XCTAssertTrue(tight.shouldCollapse("0123456789"))
        XCTAssertFalse(policy.shouldCollapse("0123456789"))
    }
}
