import XCTest
@testable import Skynet

@MainActor
final class SessionListViewModelTests: XCTestCase {
    private var relay: ScriptedRelay!
    private var router: AppRouter!
    private var sessionIndex: SessionIndex!
    private var model: SessionListViewModel!

    override func setUp() {
        super.setUp()
        relay = PreviewData.scriptedRelay()
        router = AppRouter()
        sessionIndex = SessionIndex()
        model = SessionListViewModel(
            project: PreviewData.project,
            relay: relay,
            router: router,
            sessionIndex: sessionIndex
        )
    }

    // MARK: - Loading

    func testLoadSortsSessionsByMostRecentlyUpdated() async {
        await model.load()

        XCTAssertEqual(model.sessions.count, 3)
        XCTAssertEqual(
            model.sessions.map(\.id),
            [PreviewData.permissionSession.id, PreviewData.runningSession.id, PreviewData.idleSession.id]
        )
        XCTAssertNil(model.loadError)
    }

    func testLoadRegistersSessionsInTheIndex() async {
        await model.load()
        let count = await sessionIndex.sessionCount
        XCTAssertEqual(count, 3)
    }

    // MARK: - Search

    func testSearchFiltersByTitleAndPreview() async {
        await model.load()

        model.searchQuery = "composer"
        XCTAssertEqual(model.filteredSessions.map(\.id), [PreviewData.runningSession.id])

        model.searchQuery = "retrY fix" // title of idleSession is case-insensitive "Fix flaky…"
        XCTAssertEqual(model.filteredSessions.map(\.id), [PreviewData.idleSession.id])

        model.searchQuery = "zzz-nothing"
        XCTAssertTrue(model.filteredSessions.isEmpty)
        XCTAssertTrue(model.hasEmptySearchResults)

        model.searchQuery = ""
        XCTAssertEqual(model.filteredSessions.count, 3)
        XCTAssertFalse(model.hasEmptySearchResults)
    }

    // MARK: - Creation

    func testCreateSessionInsertsAtTopAndOpensIt() async {
        await model.load()
        await model.createSession()

        XCTAssertEqual(model.sessions.first?.projectID, PreviewData.project.id)
        XCTAssertEqual(router.selectedSession?.projectID, PreviewData.project.id)
        XCTAssertEqual(router.compactPath.count, 1, "session should be pushed on the compact stack")
        let indexed = await sessionIndex.lookup(session: model.sessions[0].id)
        XCTAssertNotNil(indexed)
    }

    func testCreateSessionFailureSurfacesErrorAndDoesNotOpen() async {
        relay.createSessionError = SkynetError.connectionLost("offline")
        await model.load()
        await model.createSession()

        XCTAssertEqual(model.sessions.count, 3)
        XCTAssertNotNil(model.loadError)
        XCTAssertNil(router.selectedSession)
    }

    // MARK: - Rename

    func testRenameUpdatesListRouterAndRelay() async {
        await model.load()
        router.open(session: PreviewData.runningSession)

        await model.rename(PreviewData.runningSession, to: "Composer queue v2")

        XCTAssertEqual(relay.renameCalls.map(\.title), ["Composer queue v2"])
        XCTAssertEqual(
            model.sessions.first { $0.id == PreviewData.runningSession.id }?.title,
            "Composer queue v2"
        )
        XCTAssertEqual(router.selectedSession?.title, "Composer queue v2")
    }

    func testRenameIgnoresEmptyAndUnchangedTitles() async {
        await model.load()

        await model.rename(PreviewData.runningSession, to: "   ")
        await model.rename(PreviewData.runningSession, to: PreviewData.runningSession.title)

        XCTAssertTrue(relay.renameCalls.isEmpty)
        XCTAssertEqual(
            model.sessions.first { $0.id == PreviewData.runningSession.id }?.title,
            PreviewData.runningSession.title
        )
    }

    // MARK: - Deletion

    func testDeleteRemovesSessionAndPopsOpenDetail() async {
        await model.load()
        router.open(session: PreviewData.runningSession)

        await model.delete(PreviewData.runningSession)

        XCTAssertEqual(relay.deleteCalls, [PreviewData.runningSession.id])
        XCTAssertFalse(model.sessions.contains { $0.id == PreviewData.runningSession.id })
        XCTAssertNil(router.selectedSession, "detail column should clear")
    }

    func testDeleteKeepsDetailWhenDeletingAnotherSession() async {
        await model.load()
        router.open(session: PreviewData.runningSession)

        await model.delete(PreviewData.idleSession)

        XCTAssertEqual(router.selectedSession?.id, PreviewData.runningSession.id)
        XCTAssertEqual(model.sessions.count, 2)
    }

    func testDeleteFailureKeepsSessionAndSurfacesError() async {
        struct FailingDeleteRelay: SkynetRelay {
            let machineID = MachineID("stub")
            func connectionEvents() -> AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
            func reconnect() async {}
            func projects() async throws -> [Project] { [] }
            func sessions(in project: ProjectID) async throws -> [AgentSession] { [] }
            func createSession(in project: ProjectID, configuration: AgentConfiguration) async throws -> AgentSession {
                throw SkynetError.notPaired
            }
            func renameSession(_ sessionID: SessionID, to title: String) async throws {}
            func deleteSession(_ sessionID: SessionID) async throws { throw SkynetError.relayRejected("delete failed") }
            func availableModels() async throws -> [AgentModel] { [] }
            func updateConfiguration(_ configuration: AgentConfiguration, for sessionID: SessionID) async throws {}
            func sessionEvents(for sessionID: SessionID) -> AsyncStream<SessionEvent> { AsyncStream { $0.finish() } }
            func sendPrompt(_ prompt: PromptPayload, to sessionID: SessionID) async throws {}
            func cancelCurrentTurn(in sessionID: SessionID) async throws {}
            func resolvePermission(
                _ requestID: TranscriptItemID,
                decision: PermissionDecision,
                in sessionID: SessionID
            ) async throws {}
        }

        let model = SessionListViewModel(
            project: PreviewData.project,
            relay: FailingDeleteRelay(),
            router: router,
            sessionIndex: sessionIndex
        )
        await model.load()
        model.sessions = [PreviewData.runningSession]
        await model.delete(PreviewData.runningSession)

        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertNotNil(model.loadError)
    }
}
