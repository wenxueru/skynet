import Foundation
@testable import SkynetCore
import SkynetCoreDoubles
import Testing

@Suite("Codex model discovery")
struct CodexModelDiscoveryTests {
    func script(_ result: JSONValue) throws -> ScriptedExecutionBackend.Script {
        let response: JSONValue = ["id": 1, "result": result]
        let responseLine = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        return .init(onStdin: { data, process in
            let frames = data.split(separator: 0x0A).compactMap {
                try? JSONDecoder().decode(JSONValue.self, from: Data($0))
            }
            guard let method = frames.first?["method"]?.stringValue else { return }
            if method == "initialize" {
                process.emitStdout(#"{"id":0,"result":{}}"#)
            } else if method == "model/list" {
                process.emitStdout(responseLine)
                process.finishStdout()
            }
        })
    }

    @Test func paginatedCatalogUsesExecutionConfigurationAndCapabilities() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            try script(["data": [
                ["id": "picker-id", "model": "actual-model", "displayName": "Available",
                 "isDefault": true, "defaultReasoningEffort": "low",
                 "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "unknown"]],
                 "inputModalities": ["text"]],
                ["id": "hidden", "hidden": true],
            ], "nextCursor": "page-two"]),
            try script(["data": [["id": "actual-model"], ["id": "older-model"]], "nextCursor": nil]),
        ])
        var provider = AgentProviderDescriptor.codex
        provider.executable = "/custom/codex"
        provider.defaultArguments = ["--profile", "test"]
        provider.environment = ["CODEX_HOME": "/tmp/skynet-codex-test"]
        let catalog = try await CodexModelDiscovery.load(provider: provider, backend: backend,
                                                         workingDirectory: "/tmp/skynet")
        #expect(catalog.models.map(\.id) == [ModelID("actual-model"), ModelID("older-model")])
        #expect(catalog.models[0].supportedEfforts == [.low])
        #expect(!catalog.models[0].supportsVision)
        #expect(catalog.models[1].supportsVision)
        #expect(catalog.defaultEfforts[ModelID("actual-model")] == .low)
        #expect(catalog.defaultModelID == ModelID("actual-model"))
        #expect(backend.launchedRequests.count == 2)
        for request in backend.launchedRequests {
            #expect(request.executable == "/custom/codex")
            #expect(request.arguments == ["--profile", "test", "app-server", "--stdio"])
            #expect(request.environment == provider.environment)
            #expect(request.workingDirectory == "/tmp/skynet")
        }
        let process = try #require(backend.launchedProcesses.last)
        let frames = try process.stdinWrites.flatMap { input in
            try input.split(separator: 0x0A).map {
                try JSONDecoder().decode(JSONValue.self, from: Data($0))
            }
        }
        let list = try #require(frames.first { $0["method"]?.stringValue == "model/list" })
        #expect(list["params"]?["cursor"] == .string("page-two"))
        #expect(!frames.contains { $0["method"]?.stringValue == "thread/resume" })
        #expect(frames.compactMap { $0["method"]?.stringValue } == [
            "initialize", "initialized", "model/list",
        ])
        #expect(backend.launchedProcesses.allSatisfy { $0.wasTerminated })
    }

    @Test(arguments: [false, true])
    func malformedOrRepeatedCursorFailsAndCloses(_ repeatedCursor: Bool) async throws {
        let result: JSONValue = repeatedCursor ? ["data": [], "nextCursor": "same"] : [:]
        let backend = ScriptedExecutionBackend(scripts: [try script(result), try script(result)])
        do {
            _ = try await CodexModelDiscovery.load(provider: .codex, backend: backend)
            Issue.record("Invalid model-list response must fail")
        } catch {
            #expect(backend.launchedProcesses.allSatisfy { $0.wasTerminated })
            #expect(backend.launchedRequests.count == (repeatedCursor ? 2 : 1))
        }
    }

    @Test func timeoutIncludesBoundedStderrDiagnostics() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(stderrLines: ["simulated Codex startup diagnostic"], onStdin: { _, _ in }),
        ])
        do {
            _ = try await CodexModelDiscovery.load(
                provider: .codex, backend: backend, timeout: .milliseconds(250)
            )
            Issue.record("A silent app-server must time out")
        } catch {
            #expect(String(describing: error).contains("simulated Codex startup diagnostic"))
            #expect(String(describing: error).contains("waiting for initialize response"))
            #expect(backend.launchedProcesses.allSatisfy { $0.wasTerminated })
        }
    }

    @Test func timeoutAfterHandshakeIdentifiesTheRPCPhase() async throws {
        let backend = ScriptedExecutionBackend(scripts: [.init(onStdin: { data, process in
            let text = String(decoding: data, as: UTF8.self)
            if text.contains("\"method\":\"initialize\"") {
                process.emitStdout(#"{"id":0,"result":{}}"#)
            }
        })])
        do {
            _ = try await CodexModelDiscovery.load(provider: .codex, backend: backend,
                                                   timeout: .milliseconds(250))
            Issue.record("Missing model/list reply must time out")
        } catch {
            #expect(String(describing: error).contains("waiting for list models response"))
            #expect(backend.launchedProcesses.allSatisfy { $0.wasTerminated })
        }
    }

    @Test(arguments: [DiscoveryPause.launch, .initialized])
    private func cancelledDiscoveryDoesNotDispatchAfterSuspension(_ pause: DiscoveryPause) async throws {
        let gate = DiscoveryGate()
        let scripted = ScriptedExecutionBackend(scripts: [try script(["data": []])])
        let backend = PausedDiscoveryBackend(scripted: scripted, gate: gate, pause: pause)
        let query = Task {
            try await CodexModelDiscovery.load(provider: .codex, backend: backend,
                                               timeout: .seconds(2))
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await gate.entered), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let entered = await gate.entered
        // Release before throwing/asserting so a fixture failure cannot strand
        // the exact producer. This gate intentionally ignores cancellation.
        query.cancel()
        await gate.release()
        #expect(entered)
        await #expect(throws: CancellationError.self) { _ = try await query.value }
        let process = try #require(scripted.launchedProcesses.first)
        let methods = process.stdinWrites.flatMap { data in
            data.split(separator: 0x0A).compactMap {
                (try? JSONDecoder().decode(JSONValue.self, from: Data($0)))?["method"]?.stringValue
            }
        }
        #expect(methods == (pause == .launch ? [] : ["initialize", "initialized"]))
        #expect(process.wasTerminated)
    }

    #if os(macOS)
    @Test func cancelledDiscoveryClosesItsOwnedLocalProcessOnly() async throws {
        // Own sleep children only: no Codex executable/provider/session/account.
        let target = try LocalProcess(request: ExecutionRequest(
            executable: "/bin/sleep", arguments: ["60"], label: "catalog-cancel-target"
        ))
        defer { target.terminate() }
        let sibling = try LocalProcess(request: ExecutionRequest(
            executable: "/bin/sleep", arguments: ["60"], label: "catalog-cancel-sibling"
        ))
        defer { sibling.terminate() }
        let gate = DiscoveryGate()
        let backend = OwnedDiscoveryBackend(process: target, gate: gate)
        let query = Task { try await CodexModelDiscovery.load(provider: .codex, backend: backend) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await gate.entered), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let entered = await gate.entered
        query.cancel()
        await gate.release()
        #expect(entered)
        await #expect(throws: CancellationError.self) { _ = try await query.value }
        #expect(await gate.writes == 0)
        #expect(try await target.waitUntilExit() == 15)
        #expect(!target.process.isRunning)
        #expect(sibling.process.isRunning)
        sibling.terminate()
        #expect(try await sibling.waitUntilExit() == 15)
        #expect(!sibling.process.isRunning)
    }
    #endif
}

private enum DiscoveryPause: Sendable {
    case launch, initialized
}

private actor DiscoveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    private(set) var writes = 0

    func recordWrite() { writes += 1 }

    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct PausedDiscoveryBackend: ExecutionBackend {
    let scripted: ScriptedExecutionBackend
    let gate: DiscoveryGate
    let pause: DiscoveryPause
    var id: BackendID { scripted.id }
    var displayName: String { scripted.displayName }
    var kind: ExecutionBackendKind { scripted.kind }

    func launch(_ request: ExecutionRequest) async throws -> any ExecutionProcess {
        let process = try scripted.launch(request)
        if pause == .launch { await gate.wait() }
        return PausedDiscoveryProcess(process: process, gate: gate, pause: pause)
    }
}

private struct PausedDiscoveryProcess: ExecutionProcess {
    let process: any ExecutionProcess
    let gate: DiscoveryGate
    let pause: DiscoveryPause
    var identifier: String { process.identifier }
    var stdoutLines: AsyncThrowingStream<String, Error> { process.stdoutLines }
    var stderrLines: AsyncThrowingStream<String, Error> { process.stderrLines }

    func writeToStdin(_ data: Data) async throws {
        if pause == .initialized,
           (try? JSONDecoder().decode(JSONValue.self, from: data))?["method"]?.stringValue == "initialized" {
            await gate.wait()
        }
        await gate.recordWrite()
        try await process.writeToStdin(data)
    }
    func waitUntilExit() async throws -> Int32 { try await process.waitUntilExit() }
    func terminate() async { await process.terminate() }
}

#if os(macOS)
private struct OwnedDiscoveryBackend: ExecutionBackend {
    let process: LocalProcess
    let gate: DiscoveryGate
    let id = BackendID("owned-catalog-cancellation")
    let displayName = "Owned catalog cancellation fixture"
    let kind = ExecutionBackendKind.local

    func launch(_ request: ExecutionRequest) async throws -> any ExecutionProcess {
        await gate.wait()
        return PausedDiscoveryProcess(process: process, gate: gate, pause: .launch)
    }
}
#endif
