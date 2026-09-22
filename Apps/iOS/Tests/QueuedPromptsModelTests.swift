import XCTest
@testable import Skynet

@MainActor
final class QueuedPromptsModelTests: XCTestCase {
    func testEnqueueKeepsFIFOOrder() {
        let queue = QueuedPromptsModel()

        let first = queue.enqueue(PromptPayload(text: "one"), reason: .offline)
        let second = queue.enqueue(PromptPayload(text: "two"), reason: .turnBusy)
        queue.enqueue(PromptPayload(text: "three"), reason: .userRequested)

        XCTAssertEqual(queue.prompts.map(\.payload.text), ["one", "two", "three"])
        XCTAssertEqual(queue.nextPrompt?.id, first.id)
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(second.reason, .turnBusy)
    }

    func testRemoveAndTake() {
        let queue = QueuedPromptsModel()
        let first = queue.enqueue(PromptPayload(text: "one"), reason: .offline)
        let second = queue.enqueue(PromptPayload(text: "two"), reason: .offline)

        queue.remove(first.id)
        XCTAssertEqual(queue.prompts.map(\.payload.text), ["two"])

        let taken = queue.take(second.id)
        XCTAssertEqual(taken?.payload.text, "two")
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.take(second.id), "taking a missing id is nil")
    }

    func testFlushSendsInOrderAndClearsSentEntries() async {
        let queue = QueuedPromptsModel()
        queue.enqueue(PromptPayload(text: "one"), reason: .offline)
        queue.enqueue(PromptPayload(text: "two"), reason: .offline)
        queue.enqueue(PromptPayload(text: "three"), reason: .offline)

        var sent: [String] = []
        await queue.flush(
            shouldSend: { true },
            send: { prompt in
                sent.append(prompt.payload.text)
            }
        )

        XCTAssertEqual(sent, ["one", "two", "three"])
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.lastFlushError)
    }

    func testFlushStopsAtFirstFailureAndKeepsRemainder() async {
        let queue = QueuedPromptsModel()
        queue.enqueue(PromptPayload(text: "one"), reason: .offline)
        queue.enqueue(PromptPayload(text: "two"), reason: .offline)
        queue.enqueue(PromptPayload(text: "three"), reason: .offline)

        struct SendFailure: Error {}

        await queue.flush(
            shouldSend: { true },
            send: { prompt in
                if prompt.payload.text == "two" {
                    throw SendFailure()
                }
            }
        )

        XCTAssertEqual(
            queue.prompts.map(\.payload.text),
            ["two", "three"],
            "failed entry and everything after stay queued"
        )
        XCTAssertNotNil(queue.lastFlushError)
    }

    func testFlushRespectsShouldSend() async {
        let queue = QueuedPromptsModel()
        queue.enqueue(PromptPayload(text: "one"), reason: .offline)

        var sentCount = 0
        await queue.flush(
            shouldSend: { false },
            send: { _ in sentCount += 1 }
        )

        XCTAssertEqual(sentCount, 0)
        XCTAssertEqual(queue.count, 1)
    }

    func testFlushStopsOnceShouldSendTurnsFalse() async {
        let queue = QueuedPromptsModel()
        queue.enqueue(PromptPayload(text: "one"), reason: .offline)
        queue.enqueue(PromptPayload(text: "two"), reason: .offline)

        var sentCount = 0
        await queue.flush(
            shouldSend: { sentCount == 0 },
            send: { _ in sentCount += 1 }
        )

        XCTAssertEqual(sentCount, 1)
        XCTAssertEqual(queue.prompts.map(\.payload.text), ["two"])
    }

    func testRemoveAll() {
        let queue = QueuedPromptsModel()
        queue.enqueue(PromptPayload(text: "one"), reason: .offline)
        queue.enqueue(PromptPayload(text: "two"), reason: .offline)
        queue.removeAll()
        XCTAssertTrue(queue.isEmpty)
    }
}
