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
        if aligned.modelID == nil {
            aligned.modelID =
                configuration.provider.resolvedModelCatalog.resolvedDefaultModel?.id
        }
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
        guard !isRunning else {
            throw SkynetError.executionFailed(reason: "A turn is already running in this session.")
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
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
            resumeToken: record.providerResumeToken
        )

        // Send the *user's* view of attachments (inline or blob) to the
        // transcript, but inline bytes to the CLI.
        let userMessage = Message(
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
        lastExitCode = nil
        stderrBuffer = []
        currentTurnContext = context

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runTurn(turn, context: context, continuation: continuation)
        }
        currentTask = task
        return stream
    }

    /// Cancels the running turn, if any. Idempotent.
    public func cancelActiveTurn() async {
        currentTask?.cancel()
        await currentProcess?.terminate()
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
            let arguments =
                configuration.provider.defaultArguments
                + (try adapter.buildArguments(
                    provider: configuration.provider,
                    turn: turn,
                    permissions: sessionPermissions,
                    interactivePermissions: configuration.permissionResponder != nil
                ))
            let request = ExecutionRequest(
                executable: configuration.provider.resolvedExecutableName
                    ?? configuration.provider.kind.defaultExecutableName,
                arguments: arguments,
                environment: configuration.provider.environment,
                workingDirectory: turn.workingDirectory,
                label: "\(configuration.provider.id.rawValue):\(record.id.description.prefix(8))"
            )
            let process = try await configuration.backend.launch(request)
            currentProcess = process

            if let stdinData = try adapter.launchStdin(
                provider: configuration.provider,
                turn: turn
            ) {
                try await process.writeToStdin(stdinData)
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self, process, turn, context, continuation] in
                    guard let self else { return }
                    for try await line in process.stdoutLines {
                        if Task.isCancelled { break }
                        await self.handleOutputLine(
                            line,
                            turn: turn,
                            context: context,
                            continuation: continuation
                        )
                    }
                }
                group.addTask { [weak self, process] in
                    guard let self else { return }
                    for try await line in process.stderrLines {
                        await self.collectStderrLine(line)
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
            } else if !turnEnded {
                if let code = lastExitCode, code != 0 {
                    let stderr = stderrBuffer.joined(separator: "\n")
                    let tail = stderr.count > 2000 ? String(stderr.suffix(2000)) : stderr
                    await failTurn(
                        SkynetError.agentExited(code: code, stderr: tail),
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
    }

    // MARK: - Event handling

    private func handleOutputLine(
        _ line: String,
        turn: AgentTurnRequest,
        context: TurnContext,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        for event in adapter.parseOutputLine(line, turn: turn) {
            if case .permissionRequested = event {
                // Permission events flow through the responder path, which
                // decides whether they surface at all.
                await handlePermissionEvent(event, continuation: continuation)
                continue
            }
            await processEvent(event, continuation: continuation)
        }
    }

    private func processEvent(
        _ event: AgentEvent,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        do {
            switch event {
            case .messageCompleted(let message):
                messages.append(message)
                record.messageCount += 1
                try configuration.store?.appendMessage(message, to: record.id)
                record.updatedAt = configuration.now()
                try configuration.store?.saveSession(record)

            case .sessionTokenReceived(let token):
                record.providerResumeToken = token
                record.updatedAt = configuration.now()
                try configuration.store?.saveSession(record)

            case .turnCompleted(let summary):
                turnEnded = true
                record.status = .idle
                if let usage = summary.usage {
                    record.totalUsage += usage
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

    private func handlePermissionEvent(
        _ event: AgentEvent,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        guard case .permissionRequested(let request) = event else { return }
        let response: PermissionResponse
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

    private func collectStderrLine(_ line: String) {
        stderrBuffer.append(line)
        if stderrBuffer.count > 200 {
            stderrBuffer.removeFirst(stderrBuffer.count - 200)
        }
    }

    private func recordExit(_ code: Int32) {
        lastExitCode = code
    }
}
