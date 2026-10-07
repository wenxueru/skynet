import Foundation

/// Changes the provider-owned archive state through Codex app-server.
public enum CodexThreadArchive {
    public static func setArchived(
        _ archived: Bool,
        threadID: String,
        backend: any ExecutionBackend,
        executable: String = "codex",
        environment: [String: String] = [:],
        timeout: Duration = .seconds(45)
    ) async throws {
        if archived, backend.kind == .local,
           archivedRolloutExists(threadID: threadID, environment: environment) {
            return
        }
        do {
            try await CodexAppServerRPC.perform(
                request: CodexAppServerBridge.archiveRequest(threadID: threadID, archived: archived),
                operation: "archive",
                contextID: threadID,
                backend: backend,
                executable: executable,
                environment: environment,
                timeout: timeout
            )
        } catch {
            // The provider can move the rollout before its acknowledgement arrives.
            // Reconcile the native state before reporting an ambiguous failure.
            if archived, backend.kind == .local,
               archivedRolloutExists(threadID: threadID, environment: environment) {
                return
            }
            let state = try? await CodexAppServerRPC.perform(
                request: CodexAppServerBridge.readThreadRequest(threadID: threadID),
                operation: "read archive state",
                contextID: threadID,
                backend: backend,
                executable: executable,
                environment: environment,
                timeout: .seconds(10)
            )
            guard let path = state?["thread"]?["path"]?.stringValue else { throw error }
            let folders = URL(fileURLWithPath: path).pathComponents
            let isInArchive = folders.contains("archived_sessions")
            let matches = archived ? isInArchive : folders.contains("sessions") && !isInArchive
            guard matches else { throw error }
        }
    }

    private static func archivedRolloutExists(
        threadID: String, environment: [String: String]
    ) -> Bool {
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let codexHome = environment["CODEX_HOME"]
            ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? URL(fileURLWithPath: home).appendingPathComponent(".codex").path
        let archive = URL(fileURLWithPath: codexHome).appendingPathComponent("archived_sessions")
        let files = try? FileManager.default.contentsOfDirectory(atPath: archive.path)
        return files?.contains(where: { $0.hasSuffix("-\(threadID).jsonl") }) == true
    }
}

/// Deletes the provider-owned thread rather than only hiding a Skynet record.
public enum CodexThreadDelete {
    public static func delete(
        threadID: String,
        backend: any ExecutionBackend,
        executable: String = "codex",
        environment: [String: String] = [:],
        timeout: Duration = .seconds(45)
    ) async throws {
        do {
            try await CodexAppServerRPC.perform(
                request: CodexAppServerBridge.deleteRequest(threadID: threadID),
                operation: "delete",
                contextID: threadID,
                backend: backend,
                executable: executable,
                environment: environment,
                timeout: timeout
            )
        } catch {
            guard await isMissing(
                threadID: threadID,
                backend: backend,
                executable: executable,
                environment: environment
            ) else { throw error }
        }
    }

    private static func isMissing(
        threadID: String,
        backend: any ExecutionBackend,
        executable: String,
        environment: [String: String]
    ) async -> Bool {
        do {
            try await CodexAppServerRPC.perform(
                request: CodexAppServerBridge.readThreadRequest(threadID: threadID),
                operation: "read delete state",
                contextID: threadID,
                backend: backend,
                executable: executable,
                environment: environment,
                timeout: .seconds(10)
            )
            return false
        } catch SkynetError.executionFailed(let reason) {
            let missingThread = "Codex read delete state failed: thread not loaded: \(threadID)"
            return reason == missingThread || reason.hasPrefix("\(missingThread) (process ")
        } catch {
            return false
        }
    }
}

/// Keeps a Skynet title change in sync with the provider-owned Codex thread.
public enum CodexThreadName {
    public static func setName(
        _ name: String,
        threadID: String,
        backend: any ExecutionBackend,
        executable: String = "codex",
        environment: [String: String] = [:],
        timeout: Duration = .seconds(15)
    ) async throws {
        try await CodexAppServerRPC.perform(
            request: CodexAppServerBridge.setNameRequest(threadID: threadID, name: name),
            operation: "rename",
            contextID: threadID,
            backend: backend,
            executable: executable,
            environment: environment,
            timeout: timeout
        )
    }
}

/// Creates a provider-owned child thread containing the current history.
public enum CodexThreadFork {
    public static func fork(
        threadID: String,
        backend: any ExecutionBackend,
        executable: String = "codex",
        environment: [String: String] = [:],
        timeout: Duration = .seconds(15)
    ) async throws -> String {
        let result = try await CodexAppServerRPC.perform(
            request: CodexAppServerBridge.forkRequest(threadID: threadID),
            operation: "fork",
            contextID: threadID,
            backend: backend,
            executable: executable,
            environment: environment,
            timeout: timeout
        )
        guard let childID = result["thread"]?["id"]?.stringValue,
              childID != threadID else {
            throw SkynetError.executionFailed(reason: "Codex fork returned no new thread ID.")
        }
        return childID
    }
}
