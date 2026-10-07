import Foundation

/// An in-memory context fork. Owns one transport for the lifetime of the panel;
/// it never resumes, persists, or interrupts the parent conversation.
public actor CodexSideConversation {
    private let backend: any ExecutionBackend
    private let provider: AgentProviderDescriptor
    private let parent: String
    private let cwd: String?
    private var process: (any ExecutionProcess)?
    private var readers: [Task<Void, Never>] = []
    private var generation = UUID()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private let stderr = CodexAppServerRPC.Diagnostics.StderrCapture()
    private var processDiagnostics: String?
    private var threadID: String?
    private var turn: AgentTurnRequest?
    private var output: AsyncThrowingStream<AgentEvent, Error>.Continuation?
    private var busy = false

    public init(backend: any ExecutionBackend, provider: AgentProviderDescriptor,
                parentThreadID: String, workingDirectory: String?) {
        self.backend = backend
        self.provider = provider
        self.parent = parentThreadID
        self.cwd = workingDirectory
    }

    public func send(_ request: AgentTurnRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        guard !busy else { throw failure("A side conversation turn is already running") }
        busy = true
        do {
            try await connect()
            guard let threadID else { throw failure("Side conversation is not connected") }
            let stream = AsyncThrowingStream<AgentEvent, Error>.makeStream()
            turn = request
            output = stream.continuation
            // Side questions may read context, but may not mutate project files
            // or request additional permissions through this independent panel.
            var params: [String: JSONValue] = [
                "threadId": .string(threadID),
                "input": [["type": "text", "text": .string(request.prompt)]],
                "approvalPolicy": "never",
                "sandboxPolicy": ["type": "readOnly"],
            ]
            if let cwd { params["cwd"] = .string(cwd) }
            if let model = request.modelID { params["model"] = .string(model.rawValue) }
            if let effort = request.effort { params["effort"] = .string(effort.rawValue) }
            _ = try await rpc("turn/start", params: .object(params))
            return stream.stream
        } catch {
            await close()
            throw error
        }
    }

    public func close() async {
        let ownedProcess = process
        generation = UUID()
        process = nil
        threadID = nil
        processDiagnostics = nil
        readers.forEach { $0.cancel() }
        readers.removeAll()
        let error = CancellationError()
        let waiting = pending.values
        pending.removeAll()
        timeouts.values.forEach { $0.cancel() }
        timeouts.removeAll()
        waiting.forEach { $0.resume(throwing: error) }
        finish(error)
        await ownedProcess?.terminate()
        await stderr.reset()
    }

    private func connect() async throws {
        if process != nil, threadID != nil { return }
        let token = generation
        let launched = try await backend.launch(ExecutionRequest(
            executable: provider.executable ?? "codex",
            arguments: provider.defaultArguments + ["app-server", "--stdio"],
            environment: provider.environment, workingDirectory: cwd,
            label: "codex-side-chat"
        ))
        guard token == generation else {
            await launched.terminate()
            throw CancellationError()
        }
        process = launched
        processDiagnostics = CodexAppServerRPC.Diagnostics.context(
            backend: backend, executable: provider.executable ?? "codex",
            environment: provider.environment, process: launched
        )
        await stderr.reset()
        readers = [
            Task { [weak self] in
                do {
                    for try await line in launched.stdoutLines {
                        await self?.receive(line, generation: token)
                    }
                    await self?.disconnected(token)
                } catch { await self?.disconnected(token) }
            },
            Task { [stderr] in
                do {
                    for try await line in launched.stderrLines {
                        await stderr.append(line)
                    }
                } catch {}
            },
        ]
        do {
            _ = try await rpc("initialize", params: [
                "clientInfo": ["name": "skynet", "title": "Skynet", "version": "1.0"],
            ], requestID: 0)
            try await write(["method": "initialized", "params": [:]])
            var params: [String: JSONValue] = [
                "threadId": .string(parent), "ephemeral": true,
                "excludeTurns": true, "sandbox": "read-only", "approvalPolicy": "never",
            ]
            if let cwd { params["cwd"] = .string(cwd) }
            let result = try await rpc("thread/fork", params: .object(params))
            guard let id = result["thread"]?["id"]?.stringValue, id != parent,
                  result["thread"]?["ephemeral"] == .bool(true) else {
                throw failure("Codex did not create an independent temporary conversation")
            }
            threadID = id
        } catch {
            await close()
            throw error
        }
    }

    private func rpc(_ method: String, params: JSONValue, requestID: Int? = nil) async throws -> JSONValue {
        let id = requestID ?? nextID
        if requestID == nil { nextID += 1 }
        let token = generation
        let diagnostics = processDiagnostics ?? "process unavailable"
        let stderr = self.stderr
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                guard token == generation, pending[id] != nil else { return }
                do { try await write(["id": .number(String(id)), "method": .string(method), "params": params]) }
                catch { resolve(id, error: error, generation: token) }
            }
            timeouts[id] = Task {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                let error = CodexAppServerRPC.Diagnostics.enrich(
                    failure("Codex \(method) response timed out"),
                    context: diagnostics, stderr: await stderr.summary()
                )
                resolve(id, error: error, generation: token)
            }
        }
    }

    private func write(_ frame: JSONValue) async throws {
        guard let process else { throw failure("Side conversation connection closed") }
        try await process.writeToStdin(CodexAppServerBridge.encode(frame))
    }

    private func resolve(_ id: Int, error: Error, generation token: UUID) {
        guard token == generation else { return }
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func receive(_ line: String, generation token: UUID) async {
        guard token == generation, let frame = CodexAppServerBridge.decode(line) else { return }
        if let id = frame["id"]?.intValue, let continuation = pending.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            if let error = frame["error"] {
                continuation.resume(throwing: failure(error["message"]?.stringValue ?? "Codex request failed"))
            } else { continuation.resume(returning: frame["result"] ?? .null) }
            return
        }
        if let id = frame["id"], frame["method"] != nil {
            // No permission escalation or external client tools in side questions.
            try? await process?.writeToStdin(CodexAppServerBridge.unsupportedResponse(id: id))
            return
        }
        guard let turn, frame["params"]?["threadId"]?.stringValue == threadID else { return }
        for event in CodexAppServerBridge.events(frame, turn: turn) {
            output?.yield(event)
            switch event {
            case .turnCompleted, .turnFailed: finish(nil)
            default: break
            }
        }
    }

    private func disconnected(_ token: UUID) async {
        guard token == generation else { return }
        let error = failure("Side conversation connection ended")
        finish(error)
        await close()
    }

    private func finish(_ error: Error?) {
        if let error { output?.finish(throwing: error) } else { output?.finish() }
        output = nil
        turn = nil
        busy = false
    }

    private func failure(_ reason: String) -> SkynetError { .executionFailed(reason: reason) }
}
