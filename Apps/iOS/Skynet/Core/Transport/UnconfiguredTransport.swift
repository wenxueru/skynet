import Foundation

/// Placeholder relay used before any Mac is paired. Every call throws
/// `SkynetError.notPaired`; it exists so the app is fully constructible
/// before the integration wires a real transport (SkynetCore relay or a
/// paired-Mac link).
public final class UnpairedRelay: SkynetRelay {
    public let machineID: MachineID

    public init(machineID: MachineID = MachineID("unpaired")) {
        self.machineID = machineID
    }

    public func connectionEvents() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            continuation.yield(.disconnected(reason: "No Mac is paired yet"))
            continuation.finish()
        }
    }

    public func reconnect() async {}

    public func projects() async throws -> [Project] { throw SkynetError.notPaired }
    public func sessions(in project: ProjectID) async throws -> [AgentSession] { throw SkynetError.notPaired }
    public func createSession(in project: ProjectID, configuration: AgentConfiguration) async throws -> AgentSession {
        throw SkynetError.notPaired
    }
    public func renameSession(_ sessionID: SessionID, to title: String) async throws { throw SkynetError.notPaired }
    public func deleteSession(_ sessionID: SessionID) async throws { throw SkynetError.notPaired }
    public func availableModels() async throws -> [AgentModel] { throw SkynetError.notPaired }
    public func updateConfiguration(_ configuration: AgentConfiguration, for sessionID: SessionID) async throws {
        throw SkynetError.notPaired
    }
    public func sessionEvents(for sessionID: SessionID) -> AsyncStream<SessionEvent> {
        AsyncStream { $0.finish() }
    }
    public func sendPrompt(_ prompt: PromptPayload, to sessionID: SessionID) async throws { throw SkynetError.notPaired }
    public func cancelCurrentTurn(in sessionID: SessionID) async throws { throw SkynetError.notPaired }
    public func resolvePermission(
        _ requestID: TranscriptItemID,
        decision: PermissionDecision,
        in sessionID: SessionID
    ) async throws {
        throw SkynetError.notPaired
    }
}

/// Placeholder pairing service for the same reason as `UnpairedRelay`:
/// the integration supplies the transport-backed implementation. This one
/// simply refuses everything, which keeps unpaired UI honest.
public final class UnconfiguredPairingService: PairingService {
    private let codec = PairingCodeCodec()

    public init() {}

    public func parseCode(_ raw: String) throws -> PairingOffer {
        try codec.decode(raw)
    }

    public func beginPairing(with offer: PairingOffer) async throws -> PairingHandshake {
        throw SkynetError.notPaired
    }

    public func confirm(_ handshake: PairingHandshake, enteredCode: String) async throws -> PairingResult {
        throw SkynetError.notPaired
    }

    public func unpair(_ machineID: MachineID) async throws {
        throw SkynetError.notPaired
    }
}
