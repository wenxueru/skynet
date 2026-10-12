import Foundation

/// One paired Mac. UI models remain transport-independent; reconnects and
/// request failures are surfaced through the existing connection monitor.
public actor NetworkSkynetRelay: SkynetRelay, PairingService {
    public nonisolated let machineID = MachineID("paired-mac")
    private nonisolated let connection = EventChannel<ConnectionState>(replaysLastValue: true)
    private let store: any PairedMachineStore

    public init(store: any PairedMachineStore) {
        self.store = store
        connection.send(.disconnected(reason: nil))
    }

    public nonisolated func connectionEvents() -> AsyncStream<ConnectionState> { connection.stream() }

    public func reconnect() async {
        connection.send(.connecting)
        do {
            guard case .machine = try await call(.ping) else { throw invalidReply() }
        } catch {
            // A semantic rejection still proves the authenticated Mac is reachable.
            if case SkynetError.relayRejected = error {
                connection.send(.connected)
            } else {
                connection.send(.disconnected(reason: error.localizedDescription))
            }
        }
    }

    public func projects() async throws -> [Project] {
        guard case .projects(let values) = try await call(.projects) else { throw invalidReply() }
        return values
    }

    public func sessions(in project: ProjectID) async throws -> [AgentSession] {
        guard case .sessions(let values) = try await call(.sessions(project)) else { throw invalidReply() }
        return values
    }

    public func createSession(in project: ProjectID, configuration: AgentConfiguration) async throws -> AgentSession {
        try validatePermissions(configuration)
        guard case .session(let value) = try await call(.createSession(project, configuration)) else { throw invalidReply() }
        return value
    }

    public func renameSession(_ sessionID: SessionID, to title: String) async throws {
        try await requireOK(.rename(sessionID, title))
    }

    public func deleteSession(_ sessionID: SessionID) async throws { try await requireOK(.delete(sessionID)) }

    public func availableModels() async throws -> [AgentModel] {
        guard case .models(let values) = try await call(.models) else { throw invalidReply() }
        return values
    }

    public func updateConfiguration(_ configuration: AgentConfiguration, for sessionID: SessionID) async throws {
        try validatePermissions(configuration)
        try await requireOK(.configure(sessionID, configuration))
    }

    public func sendPrompt(_ prompt: PromptPayload, to sessionID: SessionID) async throws {
        guard !prompt.isEffectivelyEmpty else { throw SkynetError.invalidInput("Enter a message first.") }
        try await requireOK(.send(sessionID, prompt))
    }

    public func cancelCurrentTurn(in sessionID: SessionID) async throws { try await requireOK(.cancel(sessionID)) }

    public func resolvePermission(_ requestID: TranscriptItemID, decision: PermissionDecision, in sessionID: SessionID) async throws {
        guard decision != .approvedAlways else {
            throw SkynetError.invalidInput("Persistent approval can only be granted on your Mac.")
        }
        try await requireOK(.permission(sessionID, requestID, decision))
    }

    public nonisolated func sessionEvents(for sessionID: SessionID) -> AsyncStream<SessionEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            let task = Task {
                var previous: MobileSessionSnapshot?
                while !Task.isCancelled {
                    do {
                        let current = try await self.snapshot(sessionID)
                        for event in Self.events(from: previous, to: current) {
                            continuation.yield(event)
                        }
                        previous = current
                        try await Task.sleep(for: .seconds(current.session.state.isBusy ? 1 : 3))
                    } catch is CancellationError { break }
                    catch {
                        continuation.yield(.loadFailed(error.localizedDescription))
                        // Reads may reconnect. Mutating requests are never automatically retried.
                        do { try await Task.sleep(for: .seconds(3)) } catch { break }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Snapshot reconciliation preserves Mac ordering and removes transient placeholders.
    public nonisolated static func events(
        from previous: MobileSessionSnapshot?, to current: MobileSessionSnapshot
    ) -> [SessionEvent] {
        guard let previous,
              current.items.starts(with: previous.items, by: { $0.id == $1.id }) else {
            return [.snapshot(session: current.session, items: current.items)]
        }
        let oldItems = Dictionary(previous.items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var events: [SessionEvent] = current.items.compactMap { item in
            guard oldItems[item.id] != item else { return nil }
            switch item {
            case .permissionRequest(let request): return .permissionUpdated(request)
            case .toolCall(let tool): return .toolCallUpdated(tool)
            default: return .itemAppended(item)
            }
        }
        if previous.session.state != current.session.state {
            events.append(.turnStateChanged(current.session.state))
        }
        // Even an unchanged successful read clears a prior refresh error.
        events.append(.sessionUpdated(current.session))
        return events
    }

    private func snapshot(_ id: SessionID) async throws -> MobileSessionSnapshot {
        guard case .snapshot(let value) = try await call(.snapshot(id)) else { throw invalidReply() }
        return value
    }

    public nonisolated func parseCode(_ raw: String) throws -> PairingOffer {
        let offer = try PairingCodeCodec().decode(raw)
        _ = try MobileRelaySecret(offer.token)
        guard offer.relayEndpoint.scheme == "skynet-relay", offer.relayEndpoint.host != nil,
              offer.relayEndpoint.port != nil else { throw PairingError.invalidCode }
        return offer
    }

    public func beginPairing(with offer: PairingOffer) async throws -> PairingHandshake {
        guard !offer.isExpired else { throw PairingError.expired }
        guard try await store.machines().isEmpty else {
            throw PairingError.rejected("Unpair your current Mac before pairing another one.")
        }
        guard case .machine(let machine) = try await MobileRelayConnection.call(
            endpoint: offer.relayEndpoint, secret: offer.token, command: .beginPairing
        ) else { throw invalidReply() }
        // The verification digits are only shown on the Mac, not returned to the phone.
        return PairingHandshake(offer: offer, verificationCode: "", machine: machine)
    }

    public func confirm(_ handshake: PairingHandshake, enteredCode: String) async throws -> PairingResult {
        guard !handshake.offer.isExpired else { throw PairingError.expired }
        guard case .paired(let result) = try await MobileRelayConnection.call(
            endpoint: handshake.offer.relayEndpoint, secret: handshake.offer.token,
            command: .confirmPairing(code: enteredCode)
        ) else { throw invalidReply() }
        guard result.machine.id == handshake.machine.id,
              result.credential.relayEndpoint == handshake.offer.relayEndpoint else {
            throw PairingError.rejected("The pairing response does not match this Mac.")
        }
        return result
    }

    public func unpair(_ machineID: MachineID) async throws {
        guard let credential = try await store.credential(for: machineID) else { return }
        guard case .ok = try await MobileRelayConnection.call(
            endpoint: credential.relayEndpoint, secret: credential.accessToken, command: .unpair
        ) else { throw invalidReply() }
        connection.send(.disconnected(reason: "Mac unpaired."))
    }

    private func call(_ command: MobileRelayCommand) async throws -> MobileRelayReply {
        do {
            guard let machine = try await store.machines().first else { throw SkynetError.notPaired }
            guard let credential = try await store.credential(for: machine.id) else {
                throw SkynetError.missingCredential(machine.id)
            }
            let result = try await MobileRelayConnection.call(endpoint: credential.relayEndpoint,
                                                            secret: credential.accessToken, command: command)
            connection.send(.connected)
            return result
        } catch {
            if case SkynetError.relayRejected = error {
                connection.send(.connected)
            }
            if (error as? SkynetError)?.isConnectivityRelated == true {
                connection.send(.disconnected(reason: error.localizedDescription))
            }
            throw error
        }
    }

    private func requireOK(_ command: MobileRelayCommand) async throws {
        guard case .ok = try await call(command) else { throw invalidReply() }
    }

    private func validatePermissions(_ configuration: AgentConfiguration) throws {
        guard configuration.permissions == .askForEverything else {
            throw SkynetError.invalidInput("Permission policy is controlled on your Mac. Mobile requests use Ask Always.")
        }
    }

    private nonisolated func invalidReply() -> SkynetError {
        .relayRejected("Your Mac returned an unexpected response. Update both apps and try again.")
    }
}
