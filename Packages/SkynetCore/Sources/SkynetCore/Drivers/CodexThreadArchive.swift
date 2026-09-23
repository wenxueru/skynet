import Foundation

/// Changes the provider-owned archive state through Codex app-server.
public enum CodexThreadArchive {
    public static func setArchived(
        _ archived: Bool,
        threadID: String,
        backend: any ExecutionBackend,
        executable: String = "codex",
        environment: [String: String] = [:],
        timeout: Duration = .seconds(15)
    ) async throws {
        let request = ExecutionRequest(
            executable: executable,
            arguments: ["app-server", "--stdio"],
            environment: environment,
            label: "codex-archive:\(threadID)"
        )
        let process = try await backend.launch(request)
        do {
            try await process.writeToStdin(
                CodexAppServerBridge.archiveRequest(threadID: threadID, archived: archived)
            )
            try await waitForResult(from: process, timeout: timeout)
            await process.terminate()
        } catch {
            await process.terminate()
            throw error
        }
    }

    private static func waitForResult(
        from process: any ExecutionProcess,
        timeout: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for try await line in process.stdoutLines {
                    guard let frame = CodexAppServerBridge.decode(line),
                          frame["id"]?.intValue == 1 else { continue }
                    if let message = frame["error"]?["message"]?.stringValue {
                        throw SkynetError.executionFailed(reason: "Codex archive failed: \(message)")
                    }
                    guard frame["result"] != nil else {
                        throw SkynetError.executionFailed(reason: "Codex archive returned no result.")
                    }
                    return true
                }
                throw SkynetError.executionFailed(reason: "Codex app-server exited before archiving.")
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SkynetError.executionFailed(reason: "Codex archive timed out.")
            }
            group.addTask {
                for try await _ in process.stderrLines {}
                return false
            }
            do {
                while let completed = try await group.next() {
                    if completed {
                        await process.terminate()
                        group.cancelAll()
                        return
                    }
                }
                throw SkynetError.executionFailed(reason: "Codex archive returned no result.")
            } catch {
                await process.terminate()
                group.cancelAll()
                throw error
            }
        }
    }
}
