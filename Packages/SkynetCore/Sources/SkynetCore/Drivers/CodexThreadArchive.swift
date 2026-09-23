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
            try await CodexThreadMutation.perform(
                request: CodexAppServerBridge.archiveRequest(threadID: threadID, archived: archived),
                operation: "archive",
                threadID: threadID,
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
            let state = try? await CodexThreadMutation.perform(
                request: CodexAppServerBridge.readThreadRequest(threadID: threadID),
                operation: "read archive state",
                threadID: threadID,
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
        timeout: Duration = .seconds(15)
    ) async throws {
        try await CodexThreadMutation.perform(
            request: CodexAppServerBridge.deleteRequest(threadID: threadID),
            operation: "delete",
            threadID: threadID,
            backend: backend,
            executable: executable,
            environment: environment,
            timeout: timeout
        )
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
        try await CodexThreadMutation.perform(
            request: CodexAppServerBridge.setNameRequest(threadID: threadID, name: name),
            operation: "rename",
            threadID: threadID,
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
        let result = try await CodexThreadMutation.perform(
            request: CodexAppServerBridge.forkRequest(threadID: threadID),
            operation: "fork",
            threadID: threadID,
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

private enum CodexThreadMutation {
    @discardableResult
    static func perform(
        request input: Data,
        operation: String,
        threadID: String,
        backend: any ExecutionBackend,
        executable: String,
        environment: [String: String],
        timeout: Duration
    ) async throws -> JSONValue {
        let request = ExecutionRequest(
            executable: executable,
            arguments: ["app-server", "--stdio"],
            environment: environment,
            label: "codex-\(operation):\(threadID)"
        )
        let process = try await backend.launch(request)
        do {
            try await process.writeToStdin(input)
            let result = try await waitForResult(from: process, operation: operation, timeout: timeout)
            await process.terminate()
            return result
        } catch {
            await process.terminate()
            throw error
        }
    }

    private static func waitForResult(
        from process: any ExecutionProcess,
        operation: String,
        timeout: Duration
    ) async throws -> JSONValue {
        try await withThrowingTaskGroup(of: JSONValue?.self) { group in
            group.addTask {
                for try await line in process.stdoutLines {
                    guard let frame = CodexAppServerBridge.decode(line),
                          frame["id"]?.intValue == 1 else { continue }
                    if let message = frame["error"]?["message"]?.stringValue {
                        throw SkynetError.executionFailed(reason: "Codex \(operation) failed: \(message)")
                    }
                    guard let result = frame["result"] else {
                        throw SkynetError.executionFailed(reason: "Codex \(operation) returned no result.")
                    }
                    return result
                }
                throw SkynetError.executionFailed(reason: "Codex app-server exited before \(operation).")
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SkynetError.executionFailed(reason: "Codex \(operation) timed out.")
            }
            group.addTask {
                for try await _ in process.stderrLines {}
                return nil
            }
            do {
                while let completed = try await group.next() {
                    if let completed {
                        await process.terminate()
                        group.cancelAll()
                        return completed
                    }
                }
                throw SkynetError.executionFailed(reason: "Codex \(operation) returned no result.")
            } catch {
                await process.terminate()
                group.cancelAll()
                throw error
            }
        }
    }
}
