import Foundation
@testable import SkynetCore
import SkynetCoreDoubles
import Testing

#if os(macOS)
import Darwin

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

@Suite("Local process backend")
struct LocalProcessBackendTests {
    @Test func lateStdinWriteAfterExitThrowsWithoutTerminatingParent() async throws {
        let process = try LocalProcessBackend().launch(ExecutionRequest(
            executable: "/usr/bin/true", stdinMode: .writable, label: "late-stdin-test"
        ))
        #expect(try await process.waitUntilExit() == 0)
        do {
            try await process.writeToStdin(Data("late permission reply\n".utf8))
            Issue.record("A write after the child exited must fail")
        } catch {
            #expect(error.localizedDescription.contains("Writing to the agent's stdin failed"))
        }
    }

    @Test(arguments: [false, true])
    func terminationStopsOwnedChildrenAndGrandchildren(nested: Bool) async throws {
        let sibling = try LocalProcess(request: ExecutionRequest(
            executable: "/bin/sleep", arguments: ["60"],
            stdinMode: .closed, label: "unrelated-sibling-test"
        ))
        defer { sibling.terminate() }
        let childScript = "/bin/sleep 60 & child=$!; printf '%s\\n' \"$child\"; wait \"$child\""
        let script = nested ? "/bin/sh -c '\(childScript.replacingOccurrences(of: "'", with: "'\\''"))' & wait" : childScript
        let process = try LocalProcessBackend().launch(ExecutionRequest(
            executable: "/bin/sh", arguments: ["-c", script],
            stdinMode: .closed, label: "owned-descendant-test"
        ))
        var iterator = process.stdoutLines.makeAsyncIterator()
        let line = try #require(try await iterator.next())
        let childPID = try #require(pid_t(line))
        #expect(Darwin.kill(childPID, 0) == 0)

        await process.terminate()
        _ = try await process.waitUntilExit()
        // A terminated child can briefly remain as a zombie pending reaping.
        // Both absent and zombie are exited, unlike an orphaned live sleep.
        var running = true
        for _ in 0..<100 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            running = proc_pidinfo(childPID, PROC_PIDTBSDINFO, 0, &info, size) == size
                && info.pbi_status != SZOMB
            if !running { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if running { _ = Darwin.kill(childPID, SIGTERM) }
        #expect(!running)
        #expect(sibling.process.isRunning)
    }

    @Test func diagnosticsIdentifyTheChildNotTheParentPID() async throws {
        let process = try LocalProcessBackend().launch(ExecutionRequest(
            executable: "/bin/sh", arguments: ["-c", "echo $$"],
            stdinMode: .closed, label: "pid-test"
        ))
        let output = try await lines(from: process.stdoutLines)
        #expect(try await process.waitUntilExit() == 0)
        let pid = try #require(output?.first)
        #expect(process.identifier == "\(pid)/pid-test")
        #expect(pid != String(ProcessInfo.processInfo.processIdentifier))
    }

    @Test func userLocalInstallPrecedesPackageManagerFallbacks() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = LocalProcessBackend.fallbackSearchDirectories(homeDirectory: home)
        #expect(directories.first == "\(home)/.local/bin")
        #expect(directories.firstIndex(of: "/opt/homebrew/bin") == 1)
    }

    @Test func childReceivesExecutableSearchPath() async throws {
        let process = try LocalProcessBackend().launch(
            ExecutionRequest(executable: "/usr/bin/env", label: "child-path-test")
        )
        let output = try await lines(from: process.stdoutLines)
        #expect(try await process.waitUntilExit() == 0)
        let path = try #require(output?.first(where: { $0.hasPrefix("PATH=") }))
        #expect(path.split(separator: ":").contains("/opt/homebrew/bin"))
        #expect(path.contains("/.npm-global/bin"))
    }

    @Test func explicitChildPathIsPreserved() async throws {
        let process = try LocalProcessBackend().launch(
            ExecutionRequest(
                executable: "/usr/bin/env", environment: ["PATH": "/usr/bin:/bin"],
                label: "explicit-child-path-test"
            )
        )
        let output = try await lines(from: process.stdoutLines)
        #expect(try await process.waitUntilExit() == 0)
        #expect(output?.contains("PATH=/usr/bin:/bin") == true)
    }

    @Test func outputStreamsFinishWhenTheChildExits() async throws {
        let process = try LocalProcessBackend().launch(
            ExecutionRequest(
                executable: "/bin/sh",
                arguments: ["-c", "printf 'stdout\\n'; printf 'stderr\\n' >&2"],
                label: "pipe-eof-test"
            )
        )

        let stdout = Task { try await lines(from: process.stdoutLines) }
        let stderr = Task { try await lines(from: process.stderrLines) }
        let exitCode = try await process.waitUntilExit()
        #expect(exitCode == 0)
        #expect(try await stdout.value == ["stdout"])
        #expect(try await stderr.value == ["stderr"])
    }

    @Test func closedStdinDeliversEOFToTheChild() async throws {
        let process = try LocalProcessBackend().launch(
            ExecutionRequest(
                executable: "/bin/sh",
                arguments: ["-c", "if IFS= read -r line; then printf 'unexpected-input\\n'; else printf 'eof\\n'; fi"],
                stdinMode: .closed,
                label: "closed-stdin-test"
            )
        )

        let output = try await lines(from: process.stdoutLines)
        if output == nil { await process.terminate() }
        #expect(output == ["eof"])
        #expect(try await process.waitUntilExit() == 0)
    }

    @Test func writableStdinStillAcceptsInput() async throws {
        let process = try LocalProcessBackend().launch(
            ExecutionRequest(
                executable: "/bin/sh",
                arguments: ["-c", "IFS= read -r line; printf '%s\\n' \"$line\""],
                label: "writable-stdin-test"
            )
        )

        try await process.writeToStdin(Data("hello\n".utf8))
        #expect(try await lines(from: process.stdoutLines) == ["hello"])
        #expect(try await process.waitUntilExit() == 0)
    }
}

private func lines(
    from stream: AsyncThrowingStream<String, Error>,
    timeout: Duration = .seconds(2)
) async throws -> [String]? {
    try await withThrowingTaskGroup(of: [String]?.self) { group in
        group.addTask {
            var output: [String] = []
            for try await line in stream {
                output.append(line)
            }
            return output
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }

        let result = try await group.next() ?? nil
        group.cancelAll()
        return result
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
