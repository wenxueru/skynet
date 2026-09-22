import XCTest
@testable import Skynet

@MainActor
final class LibraryViewModelTests: XCTestCase {
    private var relay: ScriptedRelay!
    private var store: InMemoryPairedMachineStore!
    private var pairing: ScriptedPairingService!
    private var model: LibraryViewModel!

    override func setUp() {
        super.setUp()
        relay = PreviewData.scriptedRelay()
        store = InMemoryPairedMachineStore(machines: [PreviewData.machine, PreviewData.offlineMachine])
        pairing = ScriptedPairingService(machine: PreviewData.machine)
        model = LibraryViewModel(
            machineStore: store,
            pairing: pairing,
            relay: relay,
            sessionIndex: SessionIndex()
        )
    }

    // MARK: - Loading

    func testLoadGroupsProjectsByMachine() async {
        await model.load()

        XCTAssertEqual(model.machines.map(\.id), [PreviewData.offlineMachine.id, PreviewData.machine.id])
        XCTAssertEqual(
            Set(model.projects(for: PreviewData.machine).map(\.id)),
            [PreviewData.project.id, PreviewData.sideProject.id]
        )
        XCTAssertTrue(model.projects(for: PreviewData.offlineMachine).isEmpty)
        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.isEmpty)
    }

    func testLoadSortsProjectsByMostRecentActivity() async {
        await model.load()

        let projects = model.projects(for: PreviewData.machine)
        XCTAssertEqual(projects.map(\.id), [PreviewData.project.id, PreviewData.sideProject.id])
    }

    func testLoadRegistersProjectsWithSessionIndex() async {
        let index = SessionIndex()
        let model = LibraryViewModel(
            machineStore: store,
            pairing: pairing,
            relay: relay,
            sessionIndex: index
        )
        await model.load()

        let project = await index.project(for: PreviewData.project.id)
        XCTAssertEqual(project?.name, PreviewData.project.name)
    }

    func testNotPairedRelayIsEmptyLibraryWithoutError() async {
        let model = LibraryViewModel(
            machineStore: InMemoryPairedMachineStore(),
            pairing: pairing,
            relay: UnpairedRelay(),
            sessionIndex: SessionIndex()
        )
        await model.load()

        XCTAssertTrue(model.machines.isEmpty)
        XCTAssertTrue(model.projectsByMachine.isEmpty)
        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.isEmpty)
    }

    func testRelayFailureSurfacesLoadError() async {
        struct StubRelay: SkynetRelay {
            let machineID = MachineID("stub")
            func connectionEvents() -> AsyncStream<ConnectionState> {
                AsyncStream { $0.finish() }
            }
            func reconnect() async {}
            func projects() async throws -> [Project] { throw SkynetError.connectionLost("offline") }
            func sessions(in project: ProjectID) async throws -> [AgentSession] { [] }
            func createSession(in project: ProjectID, configuration: AgentConfiguration) async throws -> AgentSession {
                throw SkynetError.notPaired
            }
            func renameSession(_ sessionID: SessionID, to title: String) async throws {}
            func deleteSession(_ sessionID: SessionID) async throws {}
            func availableModels() async throws -> [AgentModel] { [] }
            func updateConfiguration(_ configuration: AgentConfiguration, for sessionID: SessionID) async throws {}
            func sessionEvents(for sessionID: SessionID) -> AsyncStream<SessionEvent> {
                AsyncStream { $0.finish() }
            }
            func sendPrompt(_ prompt: PromptPayload, to sessionID: SessionID) async throws {}
            func cancelCurrentTurn(in sessionID: SessionID) async throws {}
            func resolvePermission(
                _ requestID: TranscriptItemID,
                decision: PermissionDecision,
                in sessionID: SessionID
            ) async throws {}
        }

        let model = LibraryViewModel(
            machineStore: store,
            pairing: pairing,
            relay: StubRelay(),
            sessionIndex: SessionIndex()
        )
        await model.load()

        // Machines still show even when the relay is down.
        XCTAssertEqual(model.machines.count, 2)
        XCTAssertNotNil(model.loadError)
    }

    // MARK: - Orphaned projects

    func testOrphanedProjectMachineIDsFlagsUnknownMachines() async {
        let orphan = Project(
            id: ProjectID("ghost"),
            machineID: MachineID("never-paired"),
            name: "ghost",
            displayPath: "~/ghost"
        )
        relay.projectsStub = [PreviewData.project, orphan]
        await model.load()

        XCTAssertEqual(model.orphanedProjectMachineIDs, [MachineID("never-paired")])
    }

    // MARK: - Unpairing

    func testUnpairForgetsMachineAndRevokesRemotely() async {
        await model.load()
        await model.unpair(PreviewData.machine)

        XCTAssertEqual(pairing.unpairCalls, [PreviewData.machine.id])
        let remaining = try? await store.machines()
        XCTAssertEqual(remaining?.map(\.id), [PreviewData.offlineMachine.id])
    }

    func testUnpairStillForgetsLocallyWhenRelayRevocationFails() async {
        struct RejectingPairingService: PairingService {
            func parseCode(_ raw: String) throws -> PairingOffer { throw PairingError.invalidCode }
            func beginPairing(with offer: PairingOffer) async throws -> PairingHandshake {
                throw PairingError.transportFailed("nope")
            }
            func confirm(_ handshake: PairingHandshake, enteredCode: String) async throws -> PairingResult {
                throw PairingError.transportFailed("nope")
            }
            func unpair(_ machineID: MachineID) async throws {
                throw PairingError.transportFailed("relay down")
            }
        }

        let model = LibraryViewModel(
            machineStore: store,
            pairing: RejectingPairingService(),
            relay: relay,
            sessionIndex: SessionIndex()
        )
        await model.load()
        await model.unpair(PreviewData.machine)

        let remaining = try? await store.machines()
        XCTAssertEqual(remaining?.map(\.id), [PreviewData.offlineMachine.id])
    }

    // MARK: - Display helpers

    func testStatusText() {
        XCTAssertEqual(model.statusText(for: PreviewData.machine), "Online")
        XCTAssertEqual(model.statusText(for: PreviewData.offlineMachine), "Offline")
    }
}
