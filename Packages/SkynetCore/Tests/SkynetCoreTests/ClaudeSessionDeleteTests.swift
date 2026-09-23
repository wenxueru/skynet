import Foundation
import SkynetCore
import SkynetCoreDoubles
import Testing

@Suite("Claude session deletion")
struct ClaudeSessionDeleteTests {
    @Test func rejectsInvalidSessionIDBeforeLaunching() async throws {
        let backend = ScriptedExecutionBackend()
        await #expect(throws: SkynetError.self) {
            try await ClaudeSessionDelete.delete(sessionID: "../other", backend: backend)
        }
        #expect(backend.launchedRequests.isEmpty)
    }

    @Test func providerFailureDoesNotCountAsDeletion() async throws {
        let backend = ScriptedExecutionBackend(scripts: [.init(exitCode: 2)])
        await #expect(throws: SkynetError.self) {
            try await ClaudeSessionDelete.delete(
                sessionID: "10000000-0000-4000-8000-000000000001", backend: backend
            )
        }
    }

    #if os(macOS)
    @Test func removesOnlyMatchingTranscriptAndSidecar() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent(".claude/projects/example", isDirectory: true)
        let id = "10000000-0000-4000-8000-000000000001"
        let transcript = project.appendingPathComponent("\(id).jsonl")
        let sidecar = project.appendingPathComponent(id, isDirectory: true)
        let unrelated = project.appendingPathComponent("other.jsonl")
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        try Data("session".utf8).write(to: transcript)
        try Data("other".utf8).write(to: unrelated)
        try Data("tool".utf8).write(to: sidecar.appendingPathComponent("tool.txt"))

        try await ClaudeSessionDelete.delete(
            sessionID: id,
            backend: LocalProcessBackend(),
            environment: ["HOME": home.path]
        )

        #expect(!FileManager.default.fileExists(atPath: transcript.path))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }
    #endif
}
