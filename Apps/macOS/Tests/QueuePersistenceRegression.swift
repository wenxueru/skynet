import Foundation
import SkynetCore

// The runner inserts the real queue/draft persistence and mutation methods.
// Only actual provider dispatch/cancellation is substituted; those have their
// own real-send/process fixture. No account store or session is opened here.
@MainActor
final class QueuePersistenceHarness {
    // PRODUCTION_TYPES
    let store: JSONDiskStore?
    var storageDirectoryURL: URL?
    var selectedSessionID: SessionID?
    var queuedPrompts: [QueuedPrompt] = []
    var pendingAttachments: [ImageAttachment] = []
    var scheduledQueueSessionIDs: Set<SessionID> = []
    var scheduledDispatchSessionID: SessionID?
    var steeringQueuedPromptID: UUID?
    var isRunning = true
    var canSteerQueuedPrompt = false
    var errorMessage: String?
    var dispatches: [(String, [ImageAttachment], UUID?)] = []
    var cancelCount = 0

    init(store: JSONDiskStore, root: URL, sessionID: SessionID) {
        self.store = store
        storageDirectoryURL = root
        selectedSessionID = sessionID
    }

    func send(_ text: String, queuedEntry: QueuedPrompt?) {
        dispatches.append((text, pendingAttachments, queuedEntry?.id))
        pendingAttachments = []
    }
    func cancel() { cancelCount += 1 }
    func reload(_ id: SessionID) { selectedSessionID = id; loadQueue(for: id) }
    // PRODUCTION_MEMBERS
}

@main
@MainActor
enum QueuePersistenceRegression {
    static func main() {
        do { try verify() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    private static func verify() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skynet-queue-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JSONDiskStore(rootURL: root)
        let id = SessionID()
        let model = QueuePersistenceHarness(store: store, root: root, sessionID: id)
        var failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            print("\(value ? "PASS" : "FAIL"): \(label)")
            if !value { failures.append(label) }
        }
        func durable() throws -> [QueuePersistenceHarness.QueuedPrompt] {
            try JSONDecoder().decode([QueuePersistenceHarness.QueuedPrompt].self,
                from: Data(contentsOf: root.appendingPathComponent("message-queues/\(id).json")))
        }
        check(!model.enqueueDraft(" \n "), "blank queue input rejected without dispatch")
        let image = ImageAttachment(data: Data([1, 2, 3]), mediaType: "image/png", fileName: "own.png")
        model.pendingAttachments = [image]
        check(model.enqueueDraft("  first 中文  "), "running-session text and image enqueued")
        check(model.queuedPrompts.first?.text == "first 中文" && model.pendingAttachments.isEmpty
              && model.dispatches.isEmpty, "enqueue trims text and consumes only persisted attachments")
        let first = model.queuedPrompts[0]
        if case .blob(let reference) = first.attachments.first?.payload {
            check(try store.loadBlob(reference) == Data([1, 2, 3]), "queue attachment bytes persisted by real blob store")
        } else { check(false, "queue attachment bytes persisted by real blob store") }
        check(try durable().map(\.id) == [first.id], "queue identity written to real durable JSON")
        let restored = QueuePersistenceHarness(store: store, root: root, sessionID: id)
        restored.reload(id)
        check(restored.queuedPrompts.map(\.id) == [first.id]
              && restored.queuedPrompts[0].attachments == first.attachments,
              "fresh coordinator restores queued identity and attachment references")
        check(model.enqueueDraft("second"), "second immediate entry accepted")
        let second = model.queuedPrompts[1]
        model.moveQueuedPrompt(second.id, by: -1)
        let reorderedIDs = try durable().map(\.id)
        check(model.queuedPrompts.map(\.id) == [second.id, first.id]
              && reorderedIDs == [second.id, first.id], "reordering persists stable IDs")
        check(!model.canMoveQueuedPrompt(second.id, by: -1)
              && !model.canMoveQueuedPrompt(first.id, by: 1), "out-of-range queue moves disabled")
        model.canSteerQueuedPrompt = true
        model.steerQueuedPrompt(first.id)
        check(model.queuedPrompts.first?.id == first.id && model.steeringQueuedPromptID == first.id
              && model.cancelCount == 1, "Steer persists chosen priority before one cancellation request")
        model.canSteerQueuedPrompt = false
        model.steerQueuedPrompt(second.id)
        check(model.cancelCount == 1, "unavailable Steer cannot cancel or mutate priority")

        let future = Date().addingTimeInterval(3600)
        check(model.enqueueDraft("scheduled", scheduledAt: future), "future scheduled entry persisted")
        let scheduled = model.queuedPrompts.last!
        check(model.scheduledQueueSessionIDs.contains(id), "scheduled session is registered after persistence")
        check(!model.canMoveQueuedPrompt(scheduled.id, by: -1)
              && !model.canMoveQueuedPrompt(second.id, by: 1), "scheduled entry blocks crossing reorder")
        for invalid in [Date().addingTimeInterval(-1), Date().addingTimeInterval(8 * 86_400)] {
            check(!model.enqueueDraft("bad time", scheduledAt: invalid), "invalid schedule rejected without queue mutation")
        }
        check(model.queuedPrompts.count == 3, "invalid schedules leave all original entries intact")
        model.pendingAttachments = [image]
        check(!model.enqueueDraft("bad scheduled image", scheduledAt: future)
              && model.pendingAttachments.map(\.id) == [image.id], "schedule-image rejection preserves draft attachment")
        model.pendingAttachments = []
        model.scheduledDispatchSessionID = id
        model.queuedPrompts[2].dispatchStartedAt = Date()
        model.removeQueuedPrompt(scheduled.id)
        check(model.queuedPrompts.contains { $0.id == scheduled.id }, "sending scheduled entry cannot be removed")
        check(model.takeQueuedPrompt(scheduled.id) == nil, "sending scheduled entry cannot be taken for editing")
        model.scheduledDispatchSessionID = nil
        check(model.takeQueuedPrompt(scheduled.id)?.id == scheduled.id
              && !model.scheduledQueueSessionIDs.contains(id), "uncertain scheduled entry can be explicitly edited and registry clears")

        let composer = ImageAttachment(data: Data([4]), mediaType: "image/png")
        model.pendingAttachments = [composer]
        model.isRunning = false
        model.sendNextQueued(for: SessionID())
        check(model.dispatches.isEmpty, "other selected identity cannot dispatch this queue")
        model.sendNextQueued(for: id)
        check(model.dispatches.count == 1 && model.dispatches[0].2 == first.id
              && model.dispatches[0].1 == first.attachments
              && model.pendingAttachments.map(\.id) == [composer.id],
              "queue dispatch uses its images while preserving unsent composer images")
        // Dispatch stub does not acknowledge or remove an entry: actual send
        // removal/exit/Steer ordering is tested by TurnCancellationRegression.
        model.isRunning = true
        model.pendingAttachments = []
        let taken = model.takeQueuedPrompt(second.id)
        let remainingIDs = try durable().map(\.id)
        check(taken?.text == "second" && remainingIDs == [first.id], "edit takes only chosen durable entry")
        model.removeQueuedPrompt(first.id)
        check(try durable().isEmpty && model.queuedPrompts.isEmpty, "removal persists empty queue")

        let otherID = SessionID()
        model.reload(otherID)
        check(model.queuedPrompts.isEmpty, "fresh session identity starts with independent queue")
        check(model.enqueueDraft("other own fixture"), "independent fixture queue persisted")
        model.reload(id)
        check(model.queuedPrompts.isEmpty, "switching back restores only original queue")
        model.queuedPrompts = (0..<100).map { .init(text: "own \($0)", attachments: []) }
        model.pendingAttachments = [image]
        check(!model.enqueueDraft("overflow") && model.queuedPrompts.count == 100
              && model.pendingAttachments.map(\.id) == [image.id], "full queue rejects additions without consuming draft")

        model.queuedPrompts = [first, second]
        let blocker = root.appendingPathComponent("own-blocker")
        try Data([0]).write(to: blocker)
        model.storageDirectoryURL = blocker
        check(!model.enqueueDraft("own write failure") && model.queuedPrompts.map(\.id) == [first.id, second.id]
              && model.pendingAttachments.map(\.id) == [image.id], "failed queue write preserves queue and attachment draft")
        model.moveQueuedPrompt(second.id, by: -1)
        check(model.queuedPrompts.map(\.id) == [first.id, second.id], "failed reorder write leaves visible order intact")
        check(model.takeQueuedPrompt(first.id) == nil && model.queuedPrompts.count == 2,
              "failed edit write cannot lose pending entry")
        model.removeQueuedPrompt(first.id)
        check(model.queuedPrompts.count == 2, "failed removal write cannot lose pending entry")
        if !failures.isEmpty {
            throw NSError(domain: "QueueFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")])
        }
    }
}
