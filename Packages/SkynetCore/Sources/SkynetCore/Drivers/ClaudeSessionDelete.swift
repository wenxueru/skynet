import Foundation

/// Removes one Claude Code conversation from the machine that owns it.
public enum ClaudeSessionDelete {
    public static func delete(
        sessionID: String,
        backend: any ExecutionBackend,
        environment: [String: String] = [:],
        timeout: Duration = .seconds(20)
    ) async throws {
        guard let uuid = UUID(uuidString: sessionID),
              uuid.uuidString.lowercased() == sessionID.lowercased() else {
            throw SkynetError.executionFailed(reason: "Invalid Claude session ID.")
        }
        let process = try await backend.launch(ExecutionRequest(
            executable: "python3",
            arguments: ["-c", deletionScript, sessionID],
            environment: environment,
            label: "claude-delete:\(sessionID)"
        ))
        do {
            let exitCode = try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask { try await process.waitUntilExit() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw SkynetError.executionFailed(reason: "Claude session deletion timed out.")
                }
                let code = try await group.next() ?? -1
                group.cancelAll()
                return code
            }
            guard exitCode == 0 else {
                throw SkynetError.executionFailed(
                    reason: "Claude session was not found or could not be deleted (exit \(exitCode))."
                )
            }
        } catch {
            await process.terminate()
            throw error
        }
    }

    private static let deletionScript = """
    from pathlib import Path
    import shutil
    import sys

    session_id = sys.argv[1]
    root = Path.home() / '.claude' / 'projects'
    matches = [p for p in root.glob(f'*/{session_id}.jsonl') if p.is_file() and not p.is_symlink()]
    if len(matches) != 1:
        sys.exit(2)
    transcript = matches[0]
    sidecar = transcript.with_suffix('')
    if sidecar.is_symlink():
        sys.exit(3)
    if sidecar.is_dir():
        shutil.rmtree(sidecar)
    transcript.unlink()
    """
}
