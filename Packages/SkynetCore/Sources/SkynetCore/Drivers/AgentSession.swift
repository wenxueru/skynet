import Foundation

/// One live agent conversation: turns in, events out, transcript persisted.
///
/// The session actor owns all mutable conversation state. Each `send`
/// launches one turn: the user message is persisted, the provider CLI is
/// launched on the configured backend, its output is decoded into events,
/// and everything the transcript needs is folded into `Message` values and
/// appended to the store. Events are also streamed to the caller live and
/// mirrored into notifications.
///
/// A session runs on exactly one backend. Multi-device use (iOS driving a
/// Mac through the relay) uses the same session shape — only the backend
/// differs.
public actor AgentSession {
    /// Everything a session needs besides its record.
    public struct Configuration: Sendable {
        public var provider: AgentProviderDescriptor
        public var backend: any ExecutionBackend
        /// Enforces the platform process boundary. Defaults to the policy
        /// for the platform this build runs on.
        public var policy: PlatformExecutionPolicy
        public var permissions: PermissionPolicy
        /// Answers interactive permission asks when the provider supports
        /// them and the policy defers to a human.
        public var permissionResponder: (any PermissionResponder)?
        /// Persistence; `nil` runs the session transcript-less (rare, but
        /// legitimate for e.g. a fire-and-forget scratch session).
        public var store: (any PersistenceStore)?
        public var notifications: EventNotificationRouter
        public var now: @Sendable () -> Date

        public init(
            provider: AgentProviderDescriptor,
            backend: any ExecutionBackend,
            policy: PlatformExecutionPolicy = .current,
            permissions: PermissionPolicy = .askEverything,
            permissionResponder: (any PermissionResponder)? = nil,
            store: (any PersistenceStore)? = nil,
            notifications: EventNotificationRouter = EventNotificationRouter(),
            now: @Sendable @escaping () -> Date = { Date() }
        ) {
            self.provider = provider
            self.backend = backend
            self.policy = policy
            self.permissions = permissions
            self.permissionResponder = permissionResponder
            self.store = store
            self.notifications = notifications
            self.now = now
        }
    }

    public private(set) var record: SessionRecord
    public private(set) var messages: [Message] = []
    public private(set) var isRunning = false

    private let configuration: Configuration
    private let adapter: any ProviderProtocolAdapter
    /// Starts as the configured policy; `allowAlways` answers widen it for
    /// the rest of the session.
    private var sessionPermissions: PermissionPolicy
    private var currentTask: Task<Void, Never>?
    private var currentProcess: (any ExecutionProcess)?
    private var currentTurnContext: TurnContext?
    private var stderrBuffer: [String] = []
    private var lastExitCode: Int32?
    private var turnEnded = false
    private var activeWriterConflictDetected = false
    private var waitingForCodexWriter = false
    private var codexRetryStatusActive = false
    private var codexAppServerTurnID: String?
    private var codexAppServerUsage = CodexAppServerBridge.UsageTracker()
    private var codexAppServerUsageBase = TokenUsage()
    private var persistedToolCalls: Set<ToolCallID> = []
    private var persistedToolResults: Set<ToolCallID> = []

    public init(record: SessionRecord, configuration: Configuration) throws {
        try configuration.provider.validate()
        self.configuration = configuration
        self.adapter = ProviderProtocolAdapters.adapter(for: configuration.provider.kind)
        self.sessionPermissions = configuration.permissions

        // The record describes *this* session on *this* configuration;
        // reconcile it so both always agree.
        var aligned = record
        aligned.providerID = configuration.provider.id
        aligned.backendID = configuration.backend.id
        self.record = aligned
    }

    /// Loads the persisted transcript into `messages`. Call once after
    /// init when resuming a session.
    public func loadPersistedTranscript() throws {
        guard let store = configuration.store else { return }
        messages = try store.loadMessages(for: record.id)
        record.messageCount = messages.count
    }

    // MARK: - Running turns

    /// Sends one prompt and streams the turn's events.
    ///
    /// - Throws: `SkynetError.executionFailed` when a turn is already
    ///   running or the prompt is empty; `attachmentUnsupported` when the
    ///   turn carries attachments the provider cannot carry; persistence
    ///   errors when the user message cannot be recorded.
    public func send(
        _ prompt: String,
        attachments: [ImageAttachment] = []
    ) throws -> AsyncThrowingStream<AgentEvent, Error> {
        // The caller may be stopped while waiting to enter this actor. Don't
        // persist a prompt or create an independent turn for a cancelled send.
        try Task.checkCancellation()
        guard !isRunning else {
            throw SkynetError.executionFailed(reason: "A turn is already running in this session.")
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty || !attachments.isEmpty else {
            throw SkynetError.executionFailed(reason: "The prompt is empty.")
        }

        let context = TurnContext(
            sessionID: record.id,
            providerID: record.providerID,
            modelID: record.modelID
        )
        let materialized = try materialize(attachments)

        let turn = AgentTurnRequest(
            turnID: context.turnID,
            sessionID: record.id,
            providerID: record.providerID,
            prompt: trimmedPrompt,
            attachments: materialized,
            modelID: record.modelID,
            effort: record.effort,
            workingDirectory: record.workingDirectory,
            resumeToken: record.forkSourceToken ?? record.providerResumeToken,
            forkOnResume: record.forkSourceToken != nil
        )

        // Send the *user's* view of attachments (inline or blob) to the
        // transcript, but inline bytes to the CLI.
        let userMessage = Message(
            id: MessageID(context.turnID),
            origin: .user,
            content: [.text(trimmedPrompt)] + attachments.map { ContentBlock.image($0) },
            createdAt: configuration.now(),
            providerID: record.providerID
        )

        let (stream, continuation) = AsyncThrowingStream<AgentEvent, Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        // Dropping the stream cancels the turn — the UI does not need to
        // call `cancelActiveTurn` explicitly, though it may.
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason {
                Task { await self?.cancelActiveTurn() }
            }
        }

        do {
            // Persist first, then mutate in-memory state — a failed write
            // leaves the session exactly as it was.
            try configuration.store?.appendMessage(userMessage, to: record.id)
            messages.append(userMessage)
            record.messageCount += 1
            if record.title == nil {
                record.title = record.derivedTitle(from: trimmedPrompt)
            }
            record.status = .running
            record.updatedAt = configuration.now()
            try configuration.store?.saveSession(record)
        } catch let error as SkynetError {
            throw error
        } catch {
            throw SkynetError.persistenceFailure(underlying: String(describing: error))
        }

        continuation.yield(.turnStarted(context))
        continuation.yield(.messageCompleted(userMessage))

        isRunning = true
        turnEnded = false
        persistedToolCalls = []
        persistedToolResults = []
        waitingForCodexWriter = false
        codexRetryStatusActive = false
        lastExitCode = nil
        stderrBuffer = []
        currentTurnContext = context
        codexAppServerTurnID = nil
        codexAppServerUsage = .init()
        codexAppServerUsageBase = record.totalUsage

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runTurn(turn, context: context, continuation: continuation)
        }
        currentTask = task
        return stream
    }

    /// Cancels the running turn, if any. Idempotent.
    public func cancelActiveTurn() async {
        let task = currentTask
        let process = currentProcess
        task?.cancel()
        await process?.terminate()
        await task?.value
    }

    // MARK: - Turn execution

    private func runTurn(
        _ turn: AgentTurnRequest,
        context: TurnContext,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        defer {
            isRunning = false
            currentTask = nil
            currentProcess = nil
            continuation.finish()
        }
        do {
            try configuration.policy.assertCanLaunch(
                on: configuration.backend,
                operation: "Running \(configuration.provider.displayName)"
            )
            let usesCodexAppServer = configuration.provider.kind == .codex
                && (record.codexApprovalMode == .manual || !turn.attachments.isEmpty)
            var adapterArguments = usesCodexAppServer
                ? ["app-server", "--stdio"]
                : try adapter.buildArguments(
                    provider: configuration.provider,
                    turn: turn,
                    permissions: sessionPermissions,
                    interactivePermissions: configuration.permissionResponder != nil
                )
            if (configuration.provider.kind == .claudeCode
                || configuration.provider.kind == .claudeCodeCompatible),
                let mode = record.claudePermissionMode {
                adapterArguments += ["--permission-mode", mode.rawValue]
            }
            if configuration.provider.kind == .codex, let fastMode = record.codexFastMode {
                adapterArguments.insert(contentsOf: [
                    "-c", "service_tier=\"\(fastMode ? "fast" : "default")\"",
                    "-c", "features.fast_mode=\(fastMode)",
                ], at: 1)
            }
            let arguments = configuration.provider.defaultArguments + adapterArguments
            // `codex exec --cd` handles the project directory itself. Keeping
            // the Node CLI wrapper in its inherited cwd also avoids a slow or
            // blocked getcwd before the native Codex process even launches.
            let workingDirectory = configuration.provider.kind == .codex
                && !usesCodexAppServer && configuration.backend.kind == .local
                ? nil : turn.workingDirectory
            let request = ExecutionRequest(
                executable: configuration.provider.resolvedExecutableName
                    ?? configuration.provider.kind.defaultExecutableName,
                arguments: arguments,
                environment: configuration.provider.environment,
                workingDirectory: workingDirectory,
                stdinMode: configuration.provider.kind == .codex && !usesCodexAppServer
                    ? .closed : .writable,
                label: "\(configuration.provider.id.rawValue):\(record.id.description.prefix(8))"
            )
            var retryAttempt = 0
            while true {
                if Task.isCancelled {
                    await completeTurn(
                        context: context,
                        stopReason: .cancelled,
                        finalText: nil,
                        usage: nil,
                        duration: nil,
                        continuation: continuation
                    )
                    break
                }
                stderrBuffer = []
                lastExitCode = nil
                activeWriterConflictDetected = false
                let process = try await configuration.backend.launch(request)
                currentProcess = process

                let launchInput = usesCodexAppServer
                    ? try CodexAppServerBridge.initialization()
                    : try adapter.launchStdin(provider: configuration.provider, turn: turn)
                if let stdinData = launchInput {
                    try await process.writeToStdin(stdinData)
                }

                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [weak self, process, turn, context, continuation] in
                        guard let self else { return }
                        for try await line in process.stdoutLines {
                            if Task.isCancelled { break }
                            if usesCodexAppServer {
                                await self.handleCodexAppServerLine(
                                    line, turn: turn, context: context, process: process,
                                    continuation: continuation
                                )
                            } else {
                                await self.handleOutputLine(
                                    line, turn: turn, context: context, continuation: continuation
                                )
                            }
                        }
                    }
                    group.addTask { [weak self, process] in
                        guard let self else { return }
                        for try await line in process.stderrLines {
                            await self.collectStderrLine(line, continuation: continuation)
                        }
                    }
                    group.addTask { [weak self, process] in
                        let code = try await process.waitUntilExit()
                        await self?.recordExit(code)
                    }
                    try await group.waitForAll()
                }

                if Task.isCancelled {
                    await completeTurn(
                        context: context,
                        stopReason: .cancelled,
                        finalText: nil,
                        usage: nil,
                        duration: nil,
                        continuation: continuation
                    )
                    break
                }

                let stderr = stderrBuffer.joined(separator: "\n")
                let stderrTail = stderr.count > 2000 ? String(stderr.suffix(2000)) : stderr
                let hasActiveWriterConflict = activeWriterConflictDetected
                    || (lastExitCode != 0 && isCodexActiveWriterConflict(stderr: stderrTail))
                if hasActiveWriterConflict {
                    beginWaitingForCodexWriter(continuation)
                    currentProcess = nil
                    let delayMilliseconds = min(500 * (1 << min(retryAttempt, 4)), 5_000)
                    retryAttempt += 1
                    try await Task.sleep(for: .milliseconds(delayMilliseconds))
                    continue
                }

                guard !turnEnded else { break }

                if let code = lastExitCode, code != 0 {
                    await failTurn(
                        exitError(code: code, stderr: stderrTail),
                        context: context,
                        continuation: continuation
                    )
                } else if usesCodexAppServer {
                    await failTurn(
                        SkynetError.executionFailed(reason: "Codex app-server exited before completing the turn."),
                        context: context,
                        continuation: continuation
                    )
                } else {
                    // Clean exit but no result frame (older CLIs): treat the
                    // last agent message as the answer.
                    await completeTurn(
                        context: context,
                        stopReason: .completed,
                        finalText: messages.last(where: { $0.origin == .agent })?.plainText,
                        usage: nil,
                        duration: nil,
                        continuation: continuation
                    )
                }
                break
            }
        } catch is CancellationError {
            await completeTurn(
                context: context,
                stopReason: .cancelled,
                finalText: nil,
                usage: nil,
                duration: nil,
                continuation: continuation
            )
        } catch let error as SkynetError {
            await failTurn(error, context: context, continuation: continuation)
        } catch {
            await failTurn(
                SkynetError.executionFailed(reason: String(describing: error)),
                context: context,
                continuation: continuation
            )
        }
        // Keep this turn alive until its process termination finishes, even
        // if cancelling the output streams lets the task group finish early.
        if Task.isCancelled { await currentProcess?.terminate() }
    }

    // MARK: - Event handling

    private func handleCodexAppServerLine(
        _ line: String,
        turn: AgentTurnRequest,
        context: TurnContext,
        process: any ExecutionProcess,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        guard let frame = CodexAppServerBridge.decode(line) else { return }
        // Server requests have their own ID namespace; only responses match our RPC IDs.
        if frame["method"] == nil, frame["id"]?.intValue == 0 {
            if let detail = frame["error"]?["message"]?.stringValue {
                await failTurn(
                    .executionFailed(reason: "Codex app-server initialization failed: \(detail)"),
                    context: context,
                    continuation: continuation
                )
                await process.terminate()
                return
            }
            do {
                try await process.writeToStdin(CodexAppServerBridge.initializedNotification())
                try await process.writeToStdin(
                    CodexAppServerBridge.threadRequest(resumeToken: turn.resumeToken)
                )
            } catch {
                await failTurn(
                    .executionFailed(reason: "Starting the Codex session failed: \(error)"),
                    context: context,
                    continuation: continuation
                )
                await process.terminate()
            }
            return
        }
        if frame["method"] == nil, frame["id"]?.intValue == 1 {
            if let threadID = frame["result"]?["thread"]?["id"]?.stringValue {
                clearWriterWaitStatus(continuation)
                await processEvent(.sessionTokenReceived(providerSessionID: threadID), continuation: continuation)
                do {
                    try await process.writeToStdin(
                        CodexAppServerBridge.startTurn(
                            threadID: threadID,
                            turn: turn,
                            approvalMode: record.codexApprovalMode ?? .automatic
                        )
                    )
                } catch {
                    await failTurn(
                        .executionFailed(reason: "Starting Codex turn failed: \(error)"),
                        context: context,
                        continuation: continuation
                    )
                    await process.terminate()
                }
            } else {
                let detail = frame["error"]?["message"]?.stringValue ?? "Codex thread start failed"
                if isCodexActiveWriterConflict(stderr: detail) {
                    await noteCodexWriterConflict(continuation)
                } else {
                    await failTurn(
                        .executionFailed(reason: detail),
                        context: context,
                        continuation: continuation
                    )
                }
                await process.terminate()
            }
            return
        }
        if frame["method"] == nil, frame["id"]?.intValue == 2,
           let error = frame["error"]?["message"]?.stringValue {
            if isCodexActiveWriterConflict(stderr: error) {
                await noteCodexWriterConflict(continuation)
            } else {
                await failTurn(.executionFailed(reason: error), context: context, continuation: continuation)
            }
            await process.terminate()
            return
        }
        if frame["method"] == nil, frame["id"]?.intValue == 2 {
            codexAppServerTurnID = frame["result"]?["turn"]?["id"]?.stringValue
            return
        }
        if frame["method"]?.stringValue == "thread/tokenUsage/updated" {
            guard let codexAppServerTurnID,
                  frame["params"]?["threadId"]?.stringValue == record.providerResumeToken,
                  frame["params"]?["turnId"]?.stringValue == codexAppServerTurnID,
                  let usage = codexAppServerUsage.observe(frame) else { return }
            await processEvent(.usageReported(usage), continuation: continuation)
            return
        }
        if let id = frame["id"], frame["method"] != nil {
            if let request = CodexAppServerBridge.permissionRequest(frame, turn: turn) {
                let event = AgentEvent.permissionRequested(request)
                await configuration.notifications.handle(event, session: record)
                continuation.yield(event)
                let answer = await configuration.permissionResponder?.decide(request)
                    ?? PermissionResponse(requestID: request.id, decision: .deny)
                if let data = try? CodexAppServerBridge.approvalResponse(frame: frame, decision: answer.decision) {
                    try? await process.writeToStdin(data)
                }
            } else if let data = try? CodexAppServerBridge.unsupportedResponse(id: id) {
                try? await process.writeToStdin(data)
            }
            return
        }
        for event in CodexAppServerBridge.events(frame, turn: turn) {
            if case .turnFailed(let failure) = event,
               isCodexActiveWriterConflict(stderr: failure.error.localizedDescription) {
                await noteCodexWriterConflict(continuation)
                return
            }
            if case .statusUpdate(let text) = event {
                codexRetryStatusActive = text != nil
            } else if codexRetryStatusActive {
                codexRetryStatusActive = false
                continuation.yield(.statusUpdate(nil))
            }
            clearWriterWaitStatus(continuation)
            await processEvent(event, continuation: continuation)
            if case .turnCompleted = event { await process.terminate() }
            if case .turnFailed = event { await process.terminate() }
        }
    }

    private func handleOutputLine(
        _ line: String,
        turn: AgentTurnRequest,
        context: TurnContext,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        if isCodexActiveWriterConflict(stderr: line) {
            await noteCodexWriterConflict(continuation)
            return
        }
        let events = adapter.parseOutputLine(line, turn: turn)
        for event in events {
            if case .turnFailed(let failure) = event,
               isCodexActiveWriterConflict(stderr: failure.error.localizedDescription) {
                await noteCodexWriterConflict(continuation)
                return
            }
            clearWriterWaitStatus(continuation)
            if case .permissionRequested = event {
                // Permission events flow through the responder path, which
                // decides whether they surface at all.
                await handlePermissionEvent(event, continuation: continuation)
                continue
            }
            await processEvent(event, continuation: continuation)
        }
    }

    private func clearWriterWaitStatus(
        _ continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) {
        guard waitingForCodexWriter else { return }
        waitingForCodexWriter = false
        continuation.yield(.statusUpdate(nil))
    }

    private func processEvent(
        _ event: AgentEvent,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        do {
            switch event {
            case .messageCompleted(let message):
                try persistTranscriptMessage(message)

            // Claude emits complete messages containing its tool blocks already.
            // Codex's exec and app-server transports emit only tool lifecycle
            // events, including repeated item.updated notifications.
            case .toolCallStarted(let call) where configuration.provider.kind == .codex:
                if !persistedToolCalls.contains(call.id) {
                    let message = Message(
                        origin: .agent, content: [.toolCall(call)],
                        createdAt: configuration.now(), modelID: record.modelID,
                        providerID: record.providerID
                    )
                    try persistTranscriptMessage(message)
                    persistedToolCalls.insert(call.id)
                    continuation.yield(.messageCompleted(message))
                }

            case .toolCallCompleted(let result) where configuration.provider.kind == .codex:
                if !persistedToolResults.contains(result.toolCallID) {
                    let message = Message(
                        origin: .toolResult,
                        content: [.toolResult(toolCallID: result.toolCallID,
                                              content: result.content, isError: result.isError)],
                        createdAt: configuration.now(), providerID: record.providerID
                    )
                    try persistTranscriptMessage(message)
                    persistedToolResults.insert(result.toolCallID)
                    continuation.yield(.messageCompleted(message))
                }

            case .sessionTokenReceived(let token):
                if let forkSourceToken = record.forkSourceToken, token == forkSourceToken {
                    throw SkynetError.executionFailed(reason: "Claude fork did not create a new session ID.")
                }
                record.providerResumeToken = token
                record.forkSourceToken = nil
                record.updatedAt = configuration.now()
                try configuration.store?.saveSession(record)

            case .usageReported(let usage) where codexAppServerTurnID != nil:
                // The tracker emits a turn-so-far snapshot, not an increment.
                // Persist each billed response even if the turn fails/stops.
                record.totalUsage = codexAppServerUsageBase + usage
                record.updatedAt = configuration.now()
                try configuration.store?.saveSession(record)

            case .turnCompleted(let summary):
                turnEnded = true
                record.status = .idle
                if let usage = summary.usage {
                    if configuration.provider.kind == .codex, codexAppServerTurnID == nil {
                        // `codex exec` turn.completed reports the thread's
                        // cumulative total, including resumed history. Replacing
                        // also reconciles totals inflated by older app versions.
                        record.totalUsage = usage
                    } else {
                        record.totalUsage += usage
                    }
                }
                record.updatedAt = configuration.now()
                try configuration.store?.saveSession(record)

            case .turnFailed:
                turnEnded = true
                record.status = .failed
                record.updatedAt = configuration.now()
                try configuration.store?.saveSession(record)

            default:
                break
            }
        } catch let error as SkynetError {
            await failTurn(error, context: contextForCurrentEvent(event), continuation: continuation)
            await currentProcess?.terminate()
            return
        } catch {
            await failTurn(
                SkynetError.persistenceFailure(underlying: String(describing: error)),
                context: contextForCurrentEvent(event),
                continuation: continuation
            )
            await currentProcess?.terminate()
            return
        }

        await configuration.notifications.handle(event, session: record)
        continuation.yield(event)
    }

    private func persistTranscriptMessage(_ message: Message) throws {
        try configuration.store?.appendMessage(message, to: record.id)
        messages.append(message)
        record.messageCount += 1
        record.updatedAt = configuration.now()
        try configuration.store?.saveSession(record)
    }

    private func handlePermissionEvent(
        _ event: AgentEvent,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        guard case .permissionRequested(let request) = event else { return }
        var response: PermissionResponse
        switch sessionPermissions.evaluate(
            toolName: request.toolName,
            primaryArgument: request.primaryArgument
        ) {
        case .allow:
            response = PermissionResponse(requestID: request.id, decision: .allow)
        case .deny:
            response = PermissionResponse(
                requestID: request.id,
                decision: .deny,
                reason: "Denied by the Skynet permission policy"
            )
        case .ask:
            guard let responder = configuration.permissionResponder else {
                // No one to ask: deny is the only safe answer.
                response = PermissionResponse(
                    requestID: request.id,
                    decision: .deny,
                    reason: "No permission responder is configured"
                )
                break
            }
            await configuration.notifications.handle(event, session: record)
            continuation.yield(event)
            let answer = await responder.decide(request)
            if answer.decision == .allowAlways {
                // Remember for the rest of the session.
                sessionPermissions.rules.append(
                    PermissionRule(effect: .allow, toolPattern: request.toolName)
                )
            }
            response = answer
        }
        // Claude's allow response requires the effective tool input. A nil
        // UI/policy override means preserve the exact original, not omit it.
        if response.decision != .deny && response.updatedInput == nil {
            response.updatedInput = request.input
        }
        if let line = adapter.permissionResponseStdin(response) {
            try? await currentProcess?.writeToStdin(Data((line + "\n").utf8))
        }
    }

    // MARK: - Turn outcomes

    private func completeTurn(
        context: TurnContext,
        stopReason: TurnSummary.StopReason,
        finalText: String?,
        usage: TokenUsage?,
        duration: TimeInterval?,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        guard !turnEnded else { return }
        turnEnded = true
        record.status = .idle
        if let usage {
            record.totalUsage += usage
        }
        record.updatedAt = configuration.now()
        try? configuration.store?.saveSession(record)
        let summary = TurnSummary(
            context: context,
            stopReason: stopReason,
            finalText: finalText,
            usage: usage,
            duration: duration
        )
        let event = AgentEvent.turnCompleted(summary)
        continuation.yield(event)
        await configuration.notifications.handle(event, session: record)
    }

    private func failTurn(
        _ error: SkynetError,
        context: TurnContext,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        guard !turnEnded else { return }
        turnEnded = true
        record.status = .failed
        record.updatedAt = configuration.now()
        try? configuration.store?.saveSession(record)
        let event = AgentEvent.turnFailed(TurnFailure(context: context, error: error))
        continuation.yield(event)
        await configuration.notifications.handle(event, session: record)
    }

    /// Best-effort turn identity for failures detected outside a parsed
    /// frame (e.g. persistence errors).
    private func contextForCurrentEvent(_ event: AgentEvent) -> TurnContext {
        currentTurnContext
            ?? TurnContext(
                sessionID: record.id,
                providerID: record.providerID,
                modelID: record.modelID
            )
    }

    // MARK: - Plumbing

    /// Resolves blob attachments to inline bytes so adapters only ever
    /// deal with data they can put on the wire.
    private func materialize(_ attachments: [ImageAttachment]) throws -> [ImageAttachment] {
        guard !attachments.isEmpty else { return attachments }
        guard let store = configuration.store else {
            let hasBlob = attachments.contains { attachment in
                if case .blob = attachment.payload { return true }
                return false
            }
            if hasBlob {
                throw SkynetError.attachmentUnsupported(
                    provider: configuration.provider.displayName,
                    reason: "blob attachments need a persistence store to be read from"
                )
            }
            return attachments
        }
        return try attachments.map { attachment in
            guard case .blob(let reference) = attachment.payload else { return attachment }
            let data: Data
            do {
                data = try store.loadBlob(reference)
            } catch let error as SkynetError {
                throw error
            } catch {
                throw SkynetError.persistenceFailure(underlying: String(describing: error))
            }
            var inline = attachment
            inline.payload = .inline(data: data, mediaType: reference.mediaType)
            return inline
        }
    }

    private func collectStderrLine(
        _ line: String,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        stderrBuffer.append(line)
        if stderrBuffer.count > 200 {
            stderrBuffer.removeFirst(stderrBuffer.count - 200)
        }
        if isCodexActiveWriterConflict(stderr: line) {
            await noteCodexWriterConflict(continuation)
        }
    }

    private func noteCodexWriterConflict(
        _ continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        activeWriterConflictDetected = true
        beginWaitingForCodexWriter(continuation)
        await currentProcess?.terminate()
    }

    private func beginWaitingForCodexWriter(
        _ continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) {
        guard !waitingForCodexWriter else { return }
        waitingForCodexWriter = true
        continuation.yield(.statusUpdate("Waiting for this Codex session to finish…"))
    }

    private func recordExit(_ code: Int32) {
        lastExitCode = code
    }

    private func exitError(code: Int32, stderr: String) -> SkynetError {
        guard isCodexActiveWriterConflict(stderr: stderr) else {
            return .agentExited(code: code, stderr: stderr)
        }
        return .executionFailed(
            reason: "This Codex session is active in another process. Wait for that turn to finish, then retry from Skynet."
        )
    }

    private func isCodexActiveWriterConflict(stderr: String) -> Bool {
        guard configuration.provider.kind == .codex else { return false }

        let message = stderr.lowercased()
        let identifiesThreadStore = message.contains("thread-store") || message.contains("thread store")
        let identifiesThread = message.contains("thread")
        let identifiesWriterConflict = message.contains("active writer")
            || (message.contains("writer") && message.contains("active"))

        return (identifiesThreadStore && identifiesWriterConflict)
            || (identifiesThread && (
                message.contains("already active")
                    || message.contains("active turn")
                    || message.contains("thread is locked")
                    || message.contains("thread locked")
            ))
    }
}
