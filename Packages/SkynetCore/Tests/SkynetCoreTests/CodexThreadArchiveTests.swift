import Foundation
import SkynetCore
import SkynetCoreDoubles
import Testing

@Suite("Codex native archive")
struct CodexThreadArchiveTests {
    @Test(arguments: [true, false])
    func sendsProviderMutationAndWaitsForSuccess(archived: Bool) async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(onStdin: { _, process in
                process.emitStdout(#"{"id":0,"result":{}}"#)
                process.emitStdout(#"{"id":1,"result":{}}"#)
                process.finishStdout()
            }),
        ])

        try await CodexThreadArchive.setArchived(
            archived, threadID: "thread-123", backend: backend
        )

        let request = try #require(backend.launchedRequests.first)
        #expect(request.executable == "codex")
        #expect(request.arguments == ["app-server", "--stdio"])
        let process = try #require(backend.launchedProcesses.first)
        let input = String(decoding: try #require(process.stdinWrites.first), as: UTF8.self)
        let frames = input.split(separator: "\n").compactMap { line in
            try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        }
        #expect(frames.last?["method"]?.stringValue == (archived ? "thread/archive" : "thread/unarchive"))
        #expect(frames.last?["params"]?["threadId"]?.stringValue == "thread-123")
        #expect(process.wasTerminated)
    }

    @Test func providerErrorIsNotTreatedAsSuccess() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(onStdin: { _, process in
                process.emitStdout(#"{"id":1,"error":{"message":"thread not found"}}"#)
                process.finishStdout()
            }),
        ])

        await #expect(throws: SkynetError.self) {
            try await CodexThreadArchive.setArchived(
                true, threadID: "missing", backend: backend
            )
        }
        #expect(backend.launchedProcesses.first?.wasTerminated == true)
    }

    @Test func deletionUsesProviderThreadDelete() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(onStdin: { _, process in
                process.emitStdout(#"{"id":1,"result":{}}"#)
                process.finishStdout()
            }),
        ])

        try await CodexThreadDelete.delete(threadID: "thread-123", backend: backend)

        let input = String(decoding: try #require(backend.launchedProcesses.first?.stdinWrites.first), as: UTF8.self)
        let frames = input.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }
        #expect(frames.last?["method"]?.stringValue == "thread/delete")
        #expect(frames.last?["params"]?["threadId"]?.stringValue == "thread-123")
    }

    @Test func deleteTimeoutAcceptsConfirmedNativeAbsence() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(onStdin: { _, _ in }),
            .init(onStdin: { _, process in
                process.emitStdout(#"{"id":1,"error":{"code":-32600,"message":"thread not loaded: thread-123"}}"#)
                process.finishStdout()
            }),
        ])

        try await CodexThreadDelete.delete(
            threadID: "thread-123", backend: backend, timeout: .milliseconds(10)
        )

        #expect(backend.launchedRequests.count == 2)
        let verification = String(decoding: try #require(backend.launchedProcesses.last?.stdinWrites.first), as: UTF8.self)
        let frames = verification.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }
        #expect(frames.last?["method"]?.stringValue == "thread/read")
    }

    @Test func deleteTimeoutRejectsNativeThreadStillPresent() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(onStdin: { _, _ in }),
            .init(onStdin: { _, process in
                process.emitStdout(#"{"id":1,"result":{"thread":{"id":"thread-123"}}}"#)
                process.finishStdout()
            }),
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
            .init(onStdin: { _, process in
                process.emitStdout(#"{"id":1,"error":{"message":"delete failed"}}"#)
                process.finishStdout()
            }),
            .init(onStdin: { _, process in
                process.emitStdout(#"{"id":1,"error":{"message":"permission denied"}}"#)
                process.finishStdout()
            }),
        ])

        await #expect(throws: SkynetError.self) {
            try await CodexThreadDelete.delete(threadID: "thread-123", backend: backend)
        }
    }

    @Test func renameUsesProviderThreadSetName() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(onStdin: { _, process in
                process.emitStdout(#"{"id":1,"result":{}}"#)
                process.finishStdout()
            }),
        ])

        try await CodexThreadName.setName("New title", threadID: "thread-123", backend: backend)

        let input = String(decoding: try #require(backend.launchedProcesses.first?.stdinWrites.first), as: UTF8.self)
        let frames = input.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }
        #expect(frames.last?["method"]?.stringValue == "thread/setName")
        #expect(frames.last?["params"]?["threadId"]?.stringValue == "thread-123")
        #expect(frames.last?["params"]?["name"]?.stringValue == "New title")
    }

    @Test func forkReturnsDistinctNativeThreadID() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(onStdin: { _, process in
                process.emitStdout(#"{"id":1,"result":{"thread":{"id":"child-456"}}}"#)
                process.finishStdout()
            }),
        ])

        let childID = try await CodexThreadFork.fork(threadID: "parent-123", backend: backend)
        #expect(childID == "child-456")
        let input = String(decoding: try #require(backend.launchedProcesses.first?.stdinWrites.first), as: UTF8.self)
        let frames = input.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }
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
            .init(onStdin: { _, _ in }),
            .init(onStdin: { _, process in
                process.emitStdout(#"{"id":1,"result":{"thread":{"path":"/Users/test/.codex/archived_sessions/rollout-123.jsonl"}}}"#)
                process.finishStdout()
            }),
        ])

        try await CodexThreadArchive.setArchived(
            true, threadID: "thread-123", backend: backend,
            timeout: .milliseconds(10)
        )

        #expect(backend.launchedRequests.count == 2)
        let verification = String(decoding: try #require(backend.launchedProcesses.last?.stdinWrites.first), as: UTF8.self)
        let frames = verification.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }
        #expect(frames.last?["method"]?.stringValue == "thread/read")
    }

    @Test func archiveTimeoutRejectsUnchangedNativeState() async throws {
        let backend = ScriptedExecutionBackend(scripts: [
            .init(onStdin: { _, _ in }),
            .init(onStdin: { _, process in
                process.emitStdout(#"{"id":1,"result":{"thread":{"path":"/Users/test/.codex/sessions/rollout-123.jsonl"}}}"#)
                process.finishStdout()
            }),
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
