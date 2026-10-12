import Foundation
import XCTest
@testable import SkynetMobile

final class MobileRelayProtocolTests: XCTestCase {
    func testAllCommandsRoundTripAndPreserveDispatchIdentity() throws {
        let project = ProjectID("synthetic-project")
        let session = SessionID("synthetic-session")
        let item = TranscriptItemID("synthetic-item")
        let prompt = PromptPayload(text: "Synthetic prompt")
        let commands: [MobileRelayCommand] = [
            .ping, .beginPairing, .confirmPairing(code: "123456"), .unpair, .projects, .sessions(project),
            .createSession(project, .standard), .rename(session, "Example"), .delete(session), .models,
            .configure(session, .standard), .snapshot(session), .send(session, prompt), .cancel(session),
            .permission(session, item, .approvedOnce),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for command in commands {
            let request = MobileRelayRequest(credential: "synthetic-application-token", command: command)
            let encoded = try encoder.encode(request)
            let decoded = try JSONDecoder().decode(MobileRelayRequest.self, from: encoded)
            XCTAssertEqual(try encoder.encode(decoded), encoded)
            XCTAssertEqual(decoded.version, 1)
            if case .send(_, let decodedPrompt) = decoded.command {
                XCTAssertEqual(decodedPrompt.dispatchID, prompt.dispatchID)
            }
        }
    }

    func testSnapshotAndReplyRoundTrips() throws {
        let machine = Machine(id: MachineID("synthetic-machine"), displayName: "Example Mac")
        let project = Project(id: ProjectID("synthetic-project"), machineID: machine.id,
                              name: "Example", displayPath: "~/Developer/example")
        let session = AgentSession(id: SessionID("synthetic-session"), projectID: project.id, title: "Example")
        let items: [TranscriptItem] = [
            .userMessage(UserMessage(id: TranscriptItemID("synthetic-user"), text: "Hello")),
            .assistantMessage(AssistantMessage(id: TranscriptItemID("synthetic-assistant"), text: "Received")),
            .toolCall(ToolCallRecord(id: TranscriptItemID("synthetic-tool"), title: "Synthetic command")),
            .permissionRequest(PermissionRequestRecord(id: TranscriptItemID("synthetic-approval"), summary: "Example approval")),
        ]
        let snapshot = MobileSessionSnapshot(session: session, items: items)
        XCTAssertEqual(try JSONDecoder().decode(MobileSessionSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        let credential = MachineCredential(relayEndpoint: URL(string: "skynet-relay://127.0.0.1:12345")!,
                                           accessToken: "synthetic-token")
        let replies: [MobileRelayReply] = [
            .ok, .machine(machine), .paired(PairingResult(machine: machine, credential: credential)),
            .projects([project]), .sessions([session]), .session(session), .models([.balanced]),
            .snapshot(snapshot), .unauthorized("Synthetic authorization failure"), .failure("Synthetic failure"),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for reply in replies {
            let encoded = try encoder.encode(reply)
            XCTAssertEqual(try encoder.encode(JSONDecoder().decode(MobileRelayReply.self, from: encoded)), encoded)
        }
    }

    func testSecretValidationAndRandomKeySizes() throws {
        let key = try MobileRelaySecret.randomKey()
        let token = try MobileRelaySecret.randomToken()
        let secret = try MobileRelaySecret(key.base64EncodedString() + "." + token)
        XCTAssertEqual(secret.key, key)
        XCTAssertEqual(secret.token, token)
        XCTAssertEqual(key.count, 32)
        for invalid in ["", "plaintext-token", "invalid-base64.\(token)", "\(Data([1]).base64EncodedString()).\(token)",
                        "\(key.base64EncodedString()).short"] {
            XCTAssertThrowsError(try MobileRelaySecret(invalid))
        }
    }

    func testFailedTurnIsRetryable() {
        XCTAssertFalse(TurnState.failed.isBusy)
        XCTAssertTrue(TurnState.failed.acceptsNewPrompt)
        XCTAssertTrue(TurnState.running.isBusy)
        XCTAssertFalse(TurnState.running.acceptsNewPrompt)
    }

    func testSnapshotReconciliationRemovesPlaceholderAndPreservesOrdering() {
        let session = AgentSession(id: SessionID("synthetic-session"),
                                   projectID: ProjectID("synthetic-project"), title: "Example")
        let first = TranscriptItem.userMessage(UserMessage(id: TranscriptItemID("synthetic-user"), text: "Hello"))
        let placeholder = TranscriptItem.assistantMessage(AssistantMessage(
            id: TranscriptItemID("synthetic-placeholder"), text: "", isStreaming: true))
        let previous = MobileSessionSnapshot(session: session, items: [first, placeholder])
        let removed = MobileSessionSnapshot(session: session, items: [first])
        XCTAssertEqual(NetworkSkynetRelay.events(from: previous, to: removed),
                       [.snapshot(session: session, items: [first])])
        let reordered = MobileSessionSnapshot(session: session, items: [placeholder, first])
        XCTAssertEqual(NetworkSkynetRelay.events(from: previous, to: reordered),
                       [.snapshot(session: session, items: [placeholder, first])])
        XCTAssertEqual(NetworkSkynetRelay.events(from: nil, to: previous),
                       [.snapshot(session: session, items: previous.items)])
    }

    func testCompletedItemsPrecedeTurnAndMetadataUpdates() throws {
        var session = AgentSession(id: SessionID("synthetic-session"),
                                   projectID: ProjectID("synthetic-project"), title: "Example", state: .running)
        let itemID = TranscriptItemID("synthetic-assistant")
        let running = TranscriptItem.assistantMessage(AssistantMessage(id: itemID, text: "Partial", isStreaming: true))
        let previous = MobileSessionSnapshot(session: session, items: [running])
        session.state = .idle
        session.lastPreview = "Complete"
        let complete = TranscriptItem.assistantMessage(AssistantMessage(id: itemID, text: "Complete"))
        let current = MobileSessionSnapshot(session: session, items: [complete])
        let events = NetworkSkynetRelay.events(from: previous, to: current)
        XCTAssertEqual(events, [.itemAppended(complete), .turnStateChanged(.idle), .sessionUpdated(session)])
        XCTAssertEqual(NetworkSkynetRelay.events(from: current, to: current), [.sessionUpdated(session)])
        let failed = SessionEvent.loadFailed("Synthetic connectivity failure")
        XCTAssertEqual(try JSONDecoder().decode(SessionEvent.self, from: JSONEncoder().encode(failed)), failed)
    }

    func testSnapshotPrefixComparisonHandlesEmptyAndGrowingHistory() {
        let session = AgentSession(id: SessionID("synthetic-session"),
                                   projectID: ProjectID("synthetic-project"), title: "Example")
        let first = TranscriptItem.userMessage(UserMessage(id: TranscriptItemID("synthetic-first"), text: "First"))
        let second = TranscriptItem.assistantMessage(AssistantMessage(id: TranscriptItemID("synthetic-second"), text: "Second"))
        let empty = MobileSessionSnapshot(session: session, items: [])
        let one = MobileSessionSnapshot(session: session, items: [first])
        let two = MobileSessionSnapshot(session: session, items: [first, second])
        XCTAssertEqual(NetworkSkynetRelay.events(from: empty, to: empty), [.sessionUpdated(session)])
        XCTAssertEqual(NetworkSkynetRelay.events(from: empty, to: one), [.itemAppended(first), .sessionUpdated(session)])
        XCTAssertEqual(NetworkSkynetRelay.events(from: one, to: two), [.itemAppended(second), .sessionUpdated(session)])
        XCTAssertEqual(NetworkSkynetRelay.events(from: two, to: one), [.snapshot(session: session, items: [first])])
        XCTAssertEqual(NetworkSkynetRelay.events(from: two, to: empty), [.snapshot(session: session, items: [])])
    }

    func testInMemoryPairingStoresMetadataAndCredentialTogether() async throws {
        let store = InMemoryPairedMachineStore()
        let machine = Machine(id: MachineID("synthetic-machine"), displayName: "Example Mac")
        let credential = MachineCredential(relayEndpoint: URL(string: "skynet-relay://127.0.0.1:12345")!,
                                           accessToken: "synthetic-token")
        try await store.savePairing(machine: machine, credential: credential)
        let machines = try await store.machines()
        let storedCredential = try await store.credential(for: machine.id)
        XCTAssertEqual(machines, [machine])
        XCTAssertEqual(storedCredential, credential)
    }
}
