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
}
