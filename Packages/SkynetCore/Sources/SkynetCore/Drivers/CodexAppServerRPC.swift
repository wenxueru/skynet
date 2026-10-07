import Foundation

/// Shared one-shot app-server RPC transport and process diagnostics.
/// Thread operations and model discovery keep their own domain validation.
enum CodexAppServerRPC {
    @discardableResult
    static func perform(
        request input: Data,
        operation: String,
        contextID: String,
        backend: any ExecutionBackend,
        executable: String,
        environment: [String: String],
        timeout: Duration,
        defaultArguments: [String] = [],
        workingDirectory: String? = nil
    ) async throws -> JSONValue {
        try Task.checkCancellation()
        let request = ExecutionRequest(
            executable: executable,
            arguments: defaultArguments + ["app-server", "--stdio"],
            environment: environment,
            workingDirectory: workingDirectory,
            label: "codex-\(operation):\(contextID)"
        )
        let process = try await backend.launch(request)
        let diagnostics = Diagnostics.context(
            backend: backend, executable: executable, environment: environment,
            process: process
        )
        do {
            // Launch and stdin writes can suspend without noticing cancellation.
            // A cancelled query/mutation must not dispatch its next RPC afterward.
            try Task.checkCancellation()
            try await process.writeToStdin(CodexAppServerBridge.initialization())
            try Task.checkCancellation()
            let result = try await waitForResult(
                from: process,
                request: input,
                operation: operation,
                timeout: timeout,
                diagnostics: diagnostics
            )
            await process.terminate()
            try Task.checkCancellation()
            return result
        } catch {
            await process.terminate()
            throw error
        }
    }

    private static func waitForResult(
        from process: any ExecutionProcess,
        request: Data,
        operation: String,
        timeout: Duration,
        diagnostics: String
    ) async throws -> JSONValue {
        let stderr = Diagnostics.StderrCapture()
        return try await withThrowingTaskGroup(of: JSONValue?.self) { group in
            group.addTask {
                for try await line in process.stdoutLines {
                    try Task.checkCancellation()
                    guard let frame = CodexAppServerBridge.decode(line),
                          let id = frame["id"]?.intValue else { continue }
                    if id == 0 {
                        if let message = frame["error"]?["message"]?.stringValue {
                            throw SkynetError.executionFailed(
                                reason: "Codex app-server initialization failed: \(message)"
                            )
                        }
                        guard frame["result"] != nil else {
                            throw SkynetError.executionFailed(
                                reason: "Codex app-server initialization returned no result."
                            )
                        }
                        try await process.writeToStdin(
                            CodexAppServerBridge.initializedNotification()
                        )
                        try Task.checkCancellation()
                        try await process.writeToStdin(request)
                        try Task.checkCancellation()
                        await stderr.setPhase("waiting for \(operation) response")
                        continue
                    }
                    guard id == 1 else { continue }
                    if let message = frame["error"]?["message"]?.stringValue {
                        throw SkynetError.executionFailed(reason: "Codex \(operation) failed: \(message)")
                    }
                    guard let result = frame["result"] else {
                        throw SkynetError.executionFailed(reason: "Codex \(operation) returned no result.")
                    }
                    return result
                }
                throw SkynetError.executionFailed(
                    reason: "Codex app-server exited before \(operation)."
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SkynetError.executionFailed(reason: "Codex \(operation) timed out.")
            }
            group.addTask {
                for try await line in process.stderrLines {
                    await stderr.append(line)
                }
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
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                throw Diagnostics.enrich(
                    error, context: "\(diagnostics), phase: \(await stderr.phase)",
                    stderr: await stderr.summary()
                )
            }
        }
    }

    enum Diagnostics {
        actor StderrCapture {
            private var lines: [String] = []
            private(set) var phase = "waiting for initialize response"

            func setPhase(_ phase: String) { self.phase = phase }

            func append(_ line: String) {
                let value = Self.redact(line.trimmingCharacters(in: .whitespacesAndNewlines))
                guard !value.isEmpty else { return }
                lines.append(String(value.suffix(500)))
                if lines.count > 8 { lines.removeFirst(lines.count - 8) }
            }

            func summary() -> String {
                String(lines.joined(separator: "\n").suffix(1_200))
            }

            func reset() { lines.removeAll() }

            private static func redact(_ value: String) -> String {
                value
                    .replacingOccurrences(
                        of: #"(?i)(bearer\s+)[^\s]+"#, with: "$1[redacted]",
                        options: .regularExpression
                    )
                    .replacingOccurrences(
                        of: #"(?i)\b(?:sk|sess|token)[-_][A-Za-z0-9_-]{16,}\b"#,
                        with: "[redacted]", options: .regularExpression
                    )
            }
        }

        static func context(
            backend: any ExecutionBackend,
            executable: String,
            environment: [String: String],
            process: any ExecutionProcess
        ) -> String {
            var values = ["process \(process.identifier)", "backend \(backend.id.rawValue)"]
            #if os(macOS)
            if backend.kind == .local,
               let path = LocalProcessBackend.resolveExecutablePath(
                   executable, requestEnvironment: environment
               ) {
                values.append("executable \(path)")
            }
            #endif
            return values.joined(separator: ", ")
        }

        static func enrich(_ error: Error, context: String, stderr: String) -> SkynetError {
            var details = [context]
            if !stderr.isEmpty { details.append("stderr: \(stderr)") }
            let reason: String
            if case SkynetError.executionFailed(let message) = error {
                reason = message
            } else {
                reason = error.localizedDescription
            }
            return .executionFailed(reason: "\(reason) (\(details.joined(separator: "; ")))")
        }
    }
}
