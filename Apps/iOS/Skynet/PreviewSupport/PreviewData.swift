import Foundation

/// Static sample data for previews, unit tests, and UI-test fixtures.
/// Foundation-only on purpose: no UIKit dependency, so it type-checks and
/// runs on any platform.
public enum PreviewData {
    // A 1×1 gray PNG used for attachment fixtures.
    public static let onePixelPNG = Data(base64Encoded:(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ"
        + "AAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    ))!

    public static func attachment(name: String = "screenshot.png") -> ImageAttachment {
        ImageAttachment(fileName: name, mimeType: "image/png", data: onePixelPNG)
    }

    // MARK: - Machines & projects

    public static let machine = Machine(
        id: MachineID("demo-mac"),
        displayName: "Studio Mac",
        modelDescription: "MacBook Pro (16-inch)",
        osVersion: "macOS 15.3",
        status: .online,
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
        capabilities: MachineCapabilities(
            relayProtocolVersion: 1,
            maxConcurrentSessions: 3,
            supportsLiveActivities: true
        )
    )

    public static let offlineMachine = Machine(
        id: MachineID("desk-mac-mini"),
        displayName: "Den Mini",
        modelDescription: "Mac mini (M2)",
        osVersion: "macOS 15.2",
        status: .offline,
        lastSeenAt: Date(timeIntervalSince1970: 1_699_900_000)
    )

    public static let project = Project(
        id: ProjectID("skynet"),
        machineID: machine.id,
        name: "skynet",
        displayPath: "~/Developer/skynet",
        gitBranch: "main",
        lastActivityAt: Date(timeIntervalSince1970: 1_700_005_000)
    )

    public static let sideProject = Project(
        id: ProjectID("notes-app"),
        machineID: machine.id,
        name: "notes-app",
        displayPath: "~/Developer/notes-app",
        gitBranch: "feature/search",
        lastActivityAt: Date(timeIntervalSince1970: 1_699_000_000)
    )

    // MARK: - Sessions

    public static let idleSession = AgentSession(
        id: SessionID("s-idle"),
        projectID: project.id,
        title: "Fix flaky transcript tests",
        createdAt: Date(timeIntervalSince1970: 1_699_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_004_000),
        state: .idle,
        lastPreview: "All tests pass after the retry fix."
    )

    public static let runningSession = AgentSession(
        id: SessionID("s-running"),
        projectID: project.id,
        title: "Refactor composer queue",
        createdAt: Date(timeIntervalSince1970: 1_699_500_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_005_500),
        state: .running,
        lastPreview: "Running the full suite…",
        unreadCount: 3,
        configuration: AgentConfiguration(
            model: AgentModel.deep,
            effort: .thorough,
            permissions: .askForWrites
        )
    )

    public static let permissionSession = AgentSession(
        id: SessionID("s-permission"),
        projectID: project.id,
        title: "Dependency updates",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_005_900),
        state: .awaitingPermission,
        lastPreview: "Wants to run: npm install"
    )

    public static var allSessions: [AgentSession] {
        [runningSession, permissionSession, idleSession]
    }

    // MARK: - Transcript

    /// A transcript that exercises every row kind: user message with an
    /// attachment, streaming assistant message, tool calls in several states,
    /// a pending permission request, a long collapsible reply, and notices.
    public static var transcript: [TranscriptItem] {
        [
            .userMessage(UserMessage(
                id: TranscriptItemID("t-user-1"),
                text: "The transcript tests are flaky on CI. Can you dig in?",
                attachments: [attachment(name: "ci-log.png")],
                sentAt: Date(timeIntervalSince1970: 1_700_000_100)
            )),
            .assistantMessage(AssistantMessage(
                id: TranscriptItemID("t-asst-1"),
                text: "I'll start by re-running the suite locally to see which cases fail.",
                sentAt: Date(timeIntervalSince1970: 1_700_000_120)
            )),
            .toolCall(ToolCallRecord(
                id: TranscriptItemID("t-tool-1"),
                title: "npm test -- transcript",
                kind: .shell,
                arguments: "$ npm test -- --filter Transcript",
                output: """
                Test Suite 'TranscriptTests' started.
                ✔ applies delta (0.02s)
                ✔ merges tool updates (0.03s)
                ✘ collapses long messages (0.41s)
                Tests: 2 passed, 1 failed
                """,
                outputTruncated: false,
                state: .failed,
                startedAt: Date(timeIntervalSince1970: 1_700_000_130),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_190)
            )),
            .toolCall(ToolCallRecord(
                id: TranscriptItemID("t-tool-2"),
                title: "Read TranscriptViewTests.swift",
                kind: .fileRead,
                arguments: "Apps/iOS/Tests/TranscriptViewTests.swift",
                output: "312 lines",
                state: .succeeded,
                startedAt: Date(timeIntervalSince1970: 1_700_000_200),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_210)
            )),
            .assistantMessage(AssistantMessage(
                id: TranscriptItemID("t-asst-2"),
                text: "Found it — the collapse test uses a clock that races the animation. ",
                isStreaming: true,
                sentAt: Date(timeIntervalSince1970: 1_700_000_220)
            )),
            .permissionRequest(PermissionRequestRecord(
                id: TranscriptItemID("t-perm-1"),
                summary: "Run npm install @types/jest@latest",
                detail: "Installs type definitions; modifies package-lock.json.",
                scope: .command,
                requestedAt: Date(timeIntervalSince1970: 1_700_000_240)
            )),
            .systemNotice(SystemNotice(
                id: TranscriptItemID("t-notice-1"),
                text: "Relay reconnected after 3 attempts.",
                severity: .info,
                date: Date(timeIntervalSince1970: 1_700_000_260)
            )),
            .assistantMessage(AssistantMessage(
                id: TranscriptItemID("t-asst-3"),
                text: longReplyText,
                sentAt: Date(timeIntervalSince1970: 1_700_000_280)
            )),
            .systemNotice(SystemNotice(
                id: TranscriptItemID("t-notice-2"),
                text: "Previous turn was canceled on the Mac.",
                severity: .warning,
                date: Date(timeIntervalSince1970: 1_700_000_300)
            )),
        ]
    }

    /// Long enough to trip the default collapse policy.
    public static let longReplyText = """
    Here is the full picture of why the suite flakes, with every moving part
    spelled out so the fix is obvious.

    ## What the test does

    The test boots a `SessionViewModel` with a scripted relay, streams a long
    message in three chunks, and then asserts that the collapse control
    appears. The assertion runs immediately after the last chunk arrives.

    ## Why it flakes

    1. The scripted relay delivers events on a background task.
    2. The view model folds them on the main actor.
    3. The test awaits one run-loop hop, which is sometimes not enough for
       all three chunks to land.
    4. The collapse decision is computed from the message text, so a missing
       chunk makes the message short enough to skip the collapsed state.

    ## The fix

    Wait on the view model's own `items` via `AsyncStream` instead of hopping
    the run loop, and make the relay deliver chunks atomically. The tests
    then observe exactly the state the production code publishes, with no
    timing assumptions at all.

    With that in place the suite is deterministic on every runner we have,
    including the slow CI instances.
    """

    // MARK: - Wiring helpers

    /// A relay pre-loaded with machines, projects, sessions, and a rich
    /// transcript — the standard fixture for previews and UI tests.
    public static func scriptedRelay(connection: ConnectionState = .connected) -> ScriptedRelay {
        ScriptedRelay(
            machineID: machine.id,
            connectionState: connection,
            projects: [project, sideProject],
            sessions: allSessions,
            history: [
                idleSession.id: transcript,
                runningSession.id: transcript,
                permissionSession.id: transcript,
            ]
        )
    }

    /// A valid pairing code for the standard fixture machine.
    public static func pairingCode(token: String = "tok-abc123") -> String {
        PairingCodeCodec().encode(
            PairingOffer(
                relayEndpoint: URL(string: "https://mac.example:7343/relay")!,
                machineName: machine.displayName,
                token: token
            )
        )
    }
}
