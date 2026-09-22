import XCTest
@testable import Skynet

/// A fully controllable `ComposerStateProviding` for composer tests.
@MainActor
private final class StubComposerState: ComposerStateProviding {
    var currentTurnState: TurnState = .idle
    var currentConnectionState: ConnectionState = .connected
    var currentConfiguration: AgentConfiguration = .standard
    var queuedPromptCount: Int = 0
    var queuedPrompts: [QueuedPrompt] = []
    var isQueueFlushing: Bool = false
    var availableModels: [AgentModel] = AgentModel.defaultCatalog

    private(set) var sentPayloads: [PromptPayload] = []
    private(set) var queuedPayloads: [PromptPayload] = []
    private(set) var appliedConfigurations: [AgentConfiguration] = []

    func composerDidRequestSend(_ payload: PromptPayload) {
        sentPayloads.append(payload)
    }

    func composerDidRequestQueue(_ payload: PromptPayload) {
        queuedPayloads.append(payload)
    }

    func composerDidChangeConfiguration(_ configuration: AgentConfiguration) {
        appliedConfigurations.append(configuration)
    }

    func composerDidRequestSendQueuedPrompt(id: UUID) {}
    func composerDidRequestRemoveQueuedPrompt(id: UUID) {}
}

@MainActor
final class ComposerViewModelTests: XCTestCase {
    private var state: StubComposerState!
    private var model: ComposerViewModel!

    override func setUp() {
        super.setUp()
        state = StubComposerState()
        model = ComposerViewModel(state: state)
    }

    // MARK: - Send action selection

    func testEmptyDraftDisablesSend() {
        model.draftText = ""
        XCTAssertEqual(model.sendAction, .disabled)

        model.draftText = "   \n  "
        XCTAssertEqual(model.sendAction, .disabled)
    }

    func testAttachmentAloneIsSendable() {
        model.attach(PreviewData.attachment())
        XCTAssertEqual(model.sendAction, .send)
    }

    func testConnectedIdleDraftSends() {
        model.draftText = "hello"
        XCTAssertEqual(model.sendAction, .send)
        XCTAssertEqual(model.sendButtonImage, "arrow.up.circle.fill")
        XCTAssertEqual(model.sendButtonLabel, "Send")
    }

    func testBusyTurnOffersQueue() {
        state.currentTurnState = .running
        model.draftText = "hello"
        XCTAssertEqual(model.sendAction, .queue)
        XCTAssertEqual(model.sendButtonImage, "arrow.down.circle.fill")
        XCTAssertEqual(model.sendButtonLabel, "Add to queue")
    }

    func testOfflineOffersQueue() {
        state.currentConnectionState = .disconnected(reason: nil)
        model.draftText = "hello"
        XCTAssertEqual(model.sendAction, .queue)
    }

    // MARK: - Primary action

    func testPerformPrimaryActionSendsAndClearsDraft() {
        model.draftText = "run tests"
        model.attach(PreviewData.attachment())

        model.performPrimaryAction()

        XCTAssertEqual(state.sentPayloads.count, 1)
        XCTAssertEqual(state.sentPayloads.first?.text, "run tests")
        XCTAssertEqual(state.sentPayloads.first?.attachments.count, 1)
        XCTAssertTrue(model.isDraftEmpty)
        XCTAssertEqual(model.attachments.count, 0)
    }

    func testPerformPrimaryActionQueuesWhenBlocked() {
        state.currentConnectionState = .disconnected(reason: nil)
        model.draftText = "queued prompt"

        model.performPrimaryAction()

        XCTAssertEqual(state.queuedPayloads.map(\.text), ["queued prompt"])
        XCTAssertTrue(state.sentPayloads.isEmpty)
        XCTAssertTrue(model.isDraftEmpty)
    }

    func testPerformPrimaryActionIgnoresDisabledState() {
        model.performPrimaryAction()
        XCTAssertTrue(state.sentPayloads.isEmpty)
        XCTAssertTrue(state.queuedPayloads.isEmpty)
    }

    // MARK: - Attachments

    func testAttachmentCapIsEnforced() {
        for index in 0..<10 {
            let accepted = model.attach(
                PreviewData.attachment(name: "shot-\(index).png")
            )
            if index < ComposerViewModel.maxAttachments {
                XCTAssertTrue(accepted, "attachment \(index) should be accepted")
            } else {
                XCTAssertFalse(accepted, "attachment \(index) should be rejected")
            }
        }
        XCTAssertEqual(model.attachments.count, ComposerViewModel.maxAttachments)
    }

    func testRemoveAttachmentById() {
        let first = PreviewData.attachment(name: "a.png")
        let second = PreviewData.attachment(name: "b.png")
        _ = model.attach(first)
        _ = model.attach(second)

        model.removeAttachment(id: first.id)

        XCTAssertEqual(model.attachments.map(\.fileName), ["b.png"])
        XCTAssertEqual(model.attachmentTotalBytes, second.byteCount)
    }

    // MARK: - Configuration

    func testUpdateConfigurationAppliesMutationToCurrentConfiguration() {
        state.currentConfiguration = AgentConfiguration(
            model: .fast,
            effort: .minimal,
            permissions: .askForEverything
        )

        model.updateConfiguration { configuration in
            configuration.model = .deep
            configuration.effort = .thorough
        }

        XCTAssertEqual(state.appliedConfigurations.count, 1)
        let applied = state.appliedConfigurations[0]
        XCTAssertEqual(applied.model, .deep)
        XCTAssertEqual(applied.effort, .thorough)
        // Untouched fields pass through.
        XCTAssertEqual(applied.permissions, .askForEverything)
    }

    // MARK: - Passthrough

    func testDraftAndQueuePassthroughs() {
        state.queuedPromptCount = 3
        XCTAssertEqual(model.queuedPromptCount, 3)
        XCTAssertEqual(model.currentConfiguration, .standard)
    }
}
