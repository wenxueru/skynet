import Foundation
import SkynetCore
import SkynetCoreDoubles
import Testing

@Suite("Codex native archive")
struct CodexThreadArchiveTests {
    private func frames(for process: ScriptedProcess) -> [JSONValue] {
        process.stdinWrites.flatMap { input in
            input.split(separator: 0x0A).compactMap {
                try? JSONDecoder().decode(JSONValue.self, from: Data($0))
            }
        }
    }

    private func appServerScript(response: String? = #"{"id":1,"result":{}}"#)
        -> ScriptedExecutionBackend.Script
    {
        .init(onStdin: { data, process in
            let frames = data.split(separator: 0x0A).compactMap {
                try? JSONDecoder().decode(JSONValue.self, from: Data($0))
            }
            guard let frame = frames.first,
                  let method = frame["method"]?.stringValue else { return }
            if method == "initialize" {
                process.emitStdout(#"{"id":0,"result":{}}"#)
            } else if method != "initialized", let response {
                process.emitStdout(response)
                process.finishStdout()
            }
        })
    }

    @Test(arguments: [true, false])
    func sendsProviderMutationAndWaitsForSuccess(archived: Bool) async throws {
        let backend = ScriptedExecutionBackend(scripts: [appServerScript()])

        try await CodexThreadArchive.setArchived(
            archived, threadID: "thread-123", backend: backend
        )

        let request = try #require(backend.launchedRequests.first)
        #expect(request.executable == "codex")
        #expect(request.arguments == ["app-server", "--stdio"])
        let process = try #require(backend.launchedProcesses.first)
        let frames = frames(for: process)
        #expect(frames.last?["method"]?.stringValue == (archived ? "thread/archive" : "thread/unarchive"))
        #expect(frames.last?["params"]?["threadId"]?.stringValue == "thread-123")
        #expect(frames.compactMap { $0["method"]?.stringValue } == [
            "initialize", "initialized", archived ? "thread/archive" : "thread/unarchive",
        ])
        #expect(process.wasTerminated)
    }

    @Test func providerErrorIsNotTreatedAsSuccess() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            appServerScript(response: #"{"id":1,"error":{"message":"thread not found"}}"#),
        ])

        await #expect(throws: SkynetError.self) {
            try await CodexThreadArchive.setArchived(
                true, threadID: "missing", backend: backend
            )
        }
        #expect(backend.launchedProcesses.first?.wasTerminated == true)
    }

    @Test func deletionUsesProviderThreadDelete() async throws {
        let backend = ScriptedExecutionBackend(scripts: [appServerScript()])

        try await CodexThreadDelete.delete(threadID: "thread-123", backend: backend)

        let process = try #require(backend.launchedProcesses.first)
        let frames = frames(for: process)
        #expect(frames.last?["method"]?.stringValue == "thread/delete")
        #expect(frames.last?["params"]?["threadId"]?.stringValue == "thread-123")
    }

    @Test func deleteTimeoutAcceptsConfirmedNativeAbsence() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            appServerScript(response: nil),
            appServerScript(response: #"{"id":1,"error":{"code":-32600,"message":"thread not loaded: thread-123"}}"#),
        ])

        try await CodexThreadDelete.delete(
            threadID: "thread-123", backend: backend, timeout: .milliseconds(10)
        )

        #expect(backend.launchedRequests.count == 2)
        let process = try #require(backend.launchedProcesses.last)
        let frames = frames(for: process)
        #expect(frames.last?["method"]?.stringValue == "thread/read")
    }

    @Test func deleteTimeoutRejectsNativeThreadStillPresent() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            appServerScript(response: nil),
            appServerScript(response: #"{"id":1,"result":{"thread":{"id":"thread-123"}}}"#),
        ])

        await #expect(throws: SkynetError.self) {
            try await CodexThreadDelete.delete(
                threadID: "thread-123", backend: backend, timeout: .milliseconds(10)
            )
        }
        #expect(backend.launchedRequests.count == 2)
    }

    @Test func deleteRejectsUnrelatedReadError() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            appServerScript(response: #"{"id":1,"error":{"message":"delete failed"}}"#),
            appServerScript(response: #"{"id":1,"error":{"message":"permission denied"}}"#),
        ])

        await #expect(throws: SkynetError.self) {
            try await CodexThreadDelete.delete(threadID: "thread-123", backend: backend)
        }
    }

    @Test func renameUsesProviderThreadNameSet() async throws {
        let backend = ScriptedExecutionBackend(scripts: [appServerScript()])

        try await CodexThreadName.setName("New title", threadID: "thread-123", backend: backend)

        let process = try #require(backend.launchedProcesses.first)
        let frames = frames(for: process)
        #expect(frames.last?["method"]?.stringValue == "thread/name/set")
        #expect(frames.last?["params"]?["threadId"]?.stringValue == "thread-123")
        #expect(frames.last?["params"]?["name"]?.stringValue == "New title")
    }

    @Test func forkReturnsDistinctNativeThreadID() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            appServerScript(response: #"{"id":1,"result":{"thread":{"id":"child-456"}}}"#),
        ])

        let childID = try await CodexThreadFork.fork(threadID: "parent-123", backend: backend)
        #expect(childID == "child-456")
        let process = try #require(backend.launchedProcesses.first)
        let frames = frames(for: process)
        #expect(frames.last?["method"]?.stringValue == "thread/fork")
        #expect(frames.last?["params"]?["threadId"]?.stringValue == "parent-123")
    }

    @Test func timeoutTerminatesAppServer() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(onStdin: { _, _ in }),
        ])

        await #expect(throws: SkynetError.self) {
            try await CodexThreadArchive.setArchived(
                true, threadID: "stalled", backend: backend,
                timeout: .milliseconds(10)
            )
        }
        #expect(backend.launchedProcesses.first?.wasTerminated == true)
    }

    @Test func archiveTimeoutAcceptsConfirmedNativeState() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            appServerScript(response: nil),
            appServerScript(response: #"{"id":1,"result":{"thread":{"path":"/Users/test/.codex/archived_sessions/rollout-123.jsonl"}}}"#),
        ])

        try await CodexThreadArchive.setArchived(
            true, threadID: "thread-123", backend: backend,
            timeout: .milliseconds(10)
        )

        #expect(backend.launchedRequests.count == 2)
        let process = try #require(backend.launchedProcesses.last)
        let frames = frames(for: process)
        #expect(frames.last?["method"]?.stringValue == "thread/read")
    }

    @Test func archiveTimeoutRejectsUnchangedNativeState() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            appServerScript(response: nil),
            appServerScript(response: #"{"id":1,"result":{"thread":{"path":"/Users/test/.codex/sessions/rollout-123.jsonl"}}}"#),
        ])

        await #expect(throws: SkynetError.self) {
            try await CodexThreadArchive.setArchived(
                true, threadID: "thread-123", backend: backend,
                timeout: .milliseconds(10)
            )
        }
    }

    @Test func alreadyArchivedLocalRolloutNeedsNoSecondMutation() async throws {
        let directory = try TempDirectory()
        let archive = directory.url.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let threadID = "10000000-0000-4000-8000-000000000001"
        let rollout = archive.appendingPathComponent("rollout-2026-09-23-\(threadID).jsonl")
        try Data().write(to: rollout)
        let backend = ScriptedExecutionBackend()

        try await CodexThreadArchive.setArchived(
            true, threadID: threadID, backend: backend,
            environment: ["CODEX_HOME": directory.url.path]
        )

        #expect(backend.launchedRequests.isEmpty)
    }
}
