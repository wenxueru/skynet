import Foundation
import SkynetCore
import SkynetCoreDoubles
import Testing

#if os(macOS)
@Suite("SSH failure diagnostics")
struct SSHFailureDiagnosticsTests {
    @Test func omitsNonFatalCryptoAndControlSocketWarnings() {
        let reason = SSHBackend.failureReason(
            operation: "Remote transcript loading",
            exitCode: 255,
            stderr: """
            ** WARNING: connection is not using a post-quantum key exchange algorithm.
            ** This session may be vulnerable to \"store now, decrypt later\" attacks.
            ** The server may need to be upgraded. See https://openssh.com/pq.html
            ControlSocket /Users/me/.ssh/skynet-abc already exists, disabling multiplexing
            """
        )

        #expect(reason == "SSH connection failed (exit status 255). SSH reported no actionable error details.")
    }

    @Test func keepsActionableFailureAlongsideNonFatalWarnings() {
        let reason = SSHBackend.failureReason(
            operation: "Remote transcript loading",
            exitCode: 3,
            stderr: """
            ** WARNING: connection is not using a post-quantum key exchange algorithm.
            ControlSocket /Users/me/.ssh/skynet-abc already exists, disabling multiplexing
            Remote transcript exceeds the configured safety limit.
            """
        )

        #expect(reason == "Remote transcript loading failed (exit status 3): Remote transcript exceeds the configured safety limit.")
    }
}
#endif

@Suite("Platform execution policy")
struct PlatformPolicyTests {
    @Test func macOSPolicyAllowsEverything() throws {
        let local = ScriptedExecutionBackend(kind: .local)
        let ssh = ScriptedExecutionBackend(kind: .ssh)
        let relay = RelayBackend(
            pairing: nil,
            transport: InMemoryRelayTransport()
        )
        try PlatformExecutionPolicy.macOS.assertCanLaunch(on: local, operation: "test")
        try PlatformExecutionPolicy.macOS.assertCanLaunch(on: ssh, operation: "test")
        try PlatformExecutionPolicy.macOS.assertCanLaunch(on: relay, operation: "test")
    }

    @Test func iOSPolicyRejectsLocalAndSSHButAllowsRelay() throws {
        let local = ScriptedExecutionBackend(kind: .local)
        let ssh = ScriptedExecutionBackend(kind: .ssh)
        let relay = ScriptedExecutionBackend(kind: .relay)

        #expect(throws: SkynetError.self) {
            try PlatformExecutionPolicy.iOS.assertCanLaunch(on: local, operation: "Spawning a process")
        }
        #expect(throws: SkynetError.self) {
            try PlatformExecutionPolicy.iOS.assertCanLaunch(on: ssh, operation: "Spawning a process")
        }
        try PlatformExecutionPolicy.iOS.assertCanLaunch(on: relay, operation: "Relay launch")

        do {
            try PlatformExecutionPolicy.iOS.assertCanLaunch(on: local, operation: "Spawning a process")
            Issue.record("expected unsupportedOnPlatform")
        } catch let error as SkynetError {
            guard case .unsupportedOnPlatform(let operation, let platform) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(operation == "Spawning a process")
            #expect(platform == "iOS")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func currentPolicyMatchesThePlatformWeTestOn() {
        #if os(macOS)
        #expect(PlatformExecutionPolicy.current == .macOS)
        #endif
    }

    @Test func iOSPolicyIsEnforcedEndToEnd() async throws {
        // A local backend under the iOS policy cannot run a turn, even
        // though the backend type itself is constructible here.
        let backend = ScriptedExecutionBackend(
            scripts: [.init(stdoutLines: [ClaudeFrames.resultSuccess])]
        )
        let session = try AgentSession(
            record: SessionRecord(providerID: .claudeCode),
            configuration: .init(
                provider: .claudeCode,
                backend: backend,
                policy: .iOS,
                store: InMemoryStore()
            )
        )

        let events = try await collectEvents(try await session.send("hello"))

        let failure = events.compactMap(\.turnFailed).first
        guard case .unsupportedOnPlatform = failure?.error else {
            Issue.record(
                "expected unsupportedOnPlatform, got \(String(describing: failure?.error))"
            )
            return
        }
        #expect(backend.launchedRequests.isEmpty)
    }
}

@Suite("Relay backend")
struct RelayBackendTests {
    @Test func unpairedRelayRefusesToLaunch() async {
        let backend = RelayBackend(pairing: nil, transport: InMemoryRelayTransport())
        do {
            _ = try await backend.launch(
                ExecutionRequest(executable: "claude", label: "test")
            )
            Issue.record("expected relayNotPaired")
        } catch let error as SkynetError {
            guard case .relayNotPaired = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func transportFailuresBecomeRelayUnreachable() async {
        let transport = InMemoryRelayTransport()
        transport.connectError = URLError(.timedOut)
        let backend = RelayBackend(
            pairing: PairingRecord(host: "mac.example", port: 7000, macName: "Mac"),
            transport: transport
        )
        do {
            _ = try await backend.launch(
                ExecutionRequest(executable: "claude", label: "test")
            )
            Issue.record("expected relayUnreachable")
        } catch let error as SkynetError {
            guard case .relayUnreachable = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func loopbackTransportCarriesLaunchesToItsChannel() async throws {
        let transport = InMemoryRelayTransport(
            scripts: [.init(stdoutLines: [ClaudeFrames.resultSuccess])]
        )
        let pairing = PairingRecord(host: "mac.example", port: 7000, macName: "Mac")
        let backend = RelayBackend(pairing: pairing, transport: transport)

        let process = try await backend.launch(
            ExecutionRequest(executable: "claude", arguments: ["--print"], label: "relay-test")
        )
        #expect(transport.connectionCount == 1)
        #expect(transport.lastPairing == pairing)
        #expect(transport.channel.backend.launchedRequests.map(\.executable) == ["claude"])
        _ = try await process.waitUntilExit()
    }

    @Test func sessionRunsOverRelayUnderIOSPolicy() async throws {
        // The full iOS shape: relay backend, iOS policy, end-to-end turn.
        let transport = InMemoryRelayTransport(
            scripts: [
                .init(stdoutLines: [
                    ClaudeFrames.initialization,
                    ClaudeFrames.assistantText,
                    ClaudeFrames.resultSuccess,
                ])
            ]
        )
        let session = try AgentSession(
            record: SessionRecord(providerID: .claudeCode),
            configuration: .init(
                provider: .claudeCode,
                backend: RelayBackend(
                    pairing: PairingRecord(host: "mac.example", port: 7000, macName: "Mac"),
                    transport: transport
                ),
                policy: .iOS,
                store: InMemoryStore()
            )
        )

        let events = try await collectEvents(try await session.send("hello from the phone"))

        #expect(events.compactMap(\.turnCompleted).first?.stopReason == .completed)
        #expect(events.compactMap(\.sessionToken) == ["sess-123"])
        #expect(transport.channel.backend.launchedRequests.count == 1)
        let record = await session.record
        #expect(record.backendID == BackendID("relay"))
        #expect(record.status == .idle)
    }
}
