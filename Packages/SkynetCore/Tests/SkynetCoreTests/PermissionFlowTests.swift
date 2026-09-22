import Foundation
import SkynetCore
import SkynetCoreDoubles
import Testing

/// A tiny thread-safe counter for driving stdin-hook scripts.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func increment() -> Int {
        lock.lock()
        value += 1
        let current = value
        lock.unlock()
        return current
    }
}

@Suite("Session permission flow")
struct PermissionFlowTests {
    private func makeSession(
        permissions: PermissionPolicy,
        responder: (any PermissionResponder)?
    ) throws -> AgentSession {
        let backend = ScriptedExecutionBackend()
        return try AgentSession(
            record: SessionRecord(providerID: .claudeCode),
            configuration: .init(
                provider: .claudeCode,
                backend: backend,
                permissions: permissions,
                permissionResponder: responder,
                store: InMemoryStore()
            )
        )
    }

    @Test func policyDeniedToolIsAnsweredDenyWithoutAsking() async throws {
        let responder = ScriptedPermissionResponder()
        let backend = ScriptedExecutionBackend(
            scripts: [
                .init(
                    stdoutLines: [ClaudeFrames.initialization, ClaudeFrames.controlRequest],
                    onStdin: { data, process in
                        let text = String(decoding: data, as: UTF8.self)
                        if text.contains("control_response") {
                            process.emitStdout(ClaudeFrames.resultSuccess)
                            process.finishStdout()
                        }
                    }
                )
            ]
        )
        let session = try AgentSession(
            record: SessionRecord(providerID: .claudeCode),
            configuration: .init(
                provider: .claudeCode,
                backend: backend,
                permissions: PermissionPolicy(
                    rules: [PermissionRule(effect: .deny, toolPattern: "Bash")],
                    defaultEffect: .allow
                ),
                permissionResponder: responder,
                store: InMemoryStore()
            )
        )

        let events = try await collectEvents(try await session.send("clean up tmp"))

        // The deny was automatic: no event surfaced, no human asked.
        #expect(events.compactMap(\.permissionRequest).isEmpty)
        #expect(responder.requests.isEmpty)

        let stdin = backend.launchedProcesses[0].stdinWrites
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
        #expect(stdin.contains("control_response"))
        #expect(stdin.contains("\"behavior\":\"deny\""))
        #expect(events.compactMap(\.turnCompleted).first != nil)
    }

    @Test func askVerdictWithResponderSurfacesRequestAndForwardsAnswer() async throws {
        let responder = ScriptedPermissionResponder(
            responses: [PermissionResponse(requestID: "", decision: .allow)]
        )
        let backend = ScriptedExecutionBackend(
            scripts: [
                .init(
                    stdoutLines: [ClaudeFrames.initialization, ClaudeFrames.controlRequest],
                    onStdin: { data, process in
                        let text = String(decoding: data, as: UTF8.self)
                        if text.contains("control_response") {
                            process.emitStdout(ClaudeFrames.assistantText)
                            process.emitStdout(ClaudeFrames.resultSuccess)
                            process.finishStdout()
                        }
                    }
                )
            ]
        )
        let notifier = RecordingNotifier()
        let session = try AgentSession(
            record: SessionRecord(providerID: .claudeCode),
            configuration: .init(
                provider: .claudeCode,
                backend: backend,
                permissions: .askEverything,
                permissionResponder: responder,
                store: InMemoryStore(),
                notifications: EventNotificationRouter(notifiers: [notifier])
            )
        )

        let events = try await collectEvents(try await session.send("run this"))

        // The ask was surfaced exactly once, with the request details.
        let requests = events.compactMap(\.permissionRequest)
        #expect(requests.count == 1)
        #expect(requests[0].toolName == "Bash")
        #expect(requests[0].summary.contains("rm -rf /tmp/x"))

        // The responder saw the same ask and its allow went to the CLI.
        #expect(responder.requests.map(\.id) == ["req-7"])
        let stdin = backend.launchedProcesses[0].stdinWrites
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
        #expect(stdin.contains("\"behavior\":\"allow\""))

        // Permission asks interrupt the user by default.
        #expect(notifier.triggers == [.permissionRequired])
        #expect(events.compactMap(\.turnCompleted).first != nil)
    }

    @Test func askVerdictWithoutResponderDeniesSafely() async throws {
        let backend = ScriptedExecutionBackend(
            scripts: [
                .init(
                    stdoutLines: [ClaudeFrames.controlRequest],
                    onStdin: { data, process in
                        let text = String(decoding: data, as: UTF8.self)
                        if text.contains("control_response") {
                            process.emitStdout(ClaudeFrames.resultSuccess)
                            process.finishStdout()
                        }
                    }
                )
            ]
        )
        let session = try AgentSession(
            record: SessionRecord(providerID: .claudeCode),
            configuration: .init(
                provider: .claudeCode,
                backend: backend,
                permissions: .askEverything,
                store: InMemoryStore()
            )
        )

        let events = try await collectEvents(try await session.send("hi"))

        #expect(events.compactMap(\.permissionRequest).isEmpty)
        let stdin = backend.launchedProcesses[0].stdinWrites
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
        #expect(stdin.contains("\"behavior\":\"deny\""))
        #expect(events.compactMap(\.turnCompleted).first != nil)
    }

    @Test func allowAlwaysIsRememberedForTheSession() async throws {
        let responder = ScriptedPermissionResponder(
            responses: [PermissionResponse(requestID: "", decision: .allowAlways)]
        )
        let askCount = Counter()
        let backend = ScriptedExecutionBackend(
            scripts: [
                .init(
                    stdoutLines: [ClaudeFrames.controlRequest],
                    onStdin: { [askCount] data, process in
                        let text = String(decoding: data, as: UTF8.self)
                        guard text.contains("control_response") else { return }
                        switch askCount.increment() {
                        case 1:
                            // First answer (allowAlways) → ask again: the
                            // session should now auto-allow.
                            process.emitStdout(
                                #"{"type":"control_request","request_id":"req-8","payload":{"type":"permission_request","tool_name":"Bash","input":{"command":"rm -rf /tmp/y"}}}"#
                            )
                        default:
                            process.emitStdout(ClaudeFrames.resultSuccess)
                            process.finishStdout()
                        }
                    }
                )
            ]
        )
        let session = try AgentSession(
            record: SessionRecord(providerID: .claudeCode),
            configuration: .init(
                provider: .claudeCode,
                backend: backend,
                permissions: .askEverything,
                permissionResponder: responder,
                store: InMemoryStore()
            )
        )

        let events = try await collectEvents(try await session.send("clean up"))

        // The second ask never reached a human.
        #expect(responder.requests.count == 1)
        #expect(events.compactMap(\.permissionRequest).count == 1)

        let stdin = backend.launchedProcesses[0].stdinWrites
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
        // Both answers were allow (first explicit, second remembered).
        #expect(stdin.components(separatedBy: "\"behavior\":\"allow\"").count == 3)
        #expect(!stdin.contains("\"behavior\":\"deny\""))
        #expect(events.compactMap(\.turnCompleted).first != nil)
    }
}
