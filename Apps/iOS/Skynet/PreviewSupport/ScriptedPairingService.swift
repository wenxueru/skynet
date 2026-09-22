import Foundation

/// Deterministic `PairingService` for previews and tests. The flow mirrors
/// the real handshake: parse → begin → confirm code → machine.
public final class ScriptedPairingService: PairingService, @unchecked Sendable {
    /// Code the "Mac" displays during the handshake.
    public var expectedCode: String
    /// Machine returned after a successful confirm.
    public var machineToReturn: Machine
    /// Credential the relay issues on success.
    public var credential = MachineCredential(
        relayEndpoint: URL(string: "https://mac.example:7343/relay")!,
        accessToken: "preview-access-token"
    )
    /// When set, `beginPairing` throws this.
    public var beginError: Error?
    /// When set, `confirm` throws this (after code comparison).
    public var confirmError: Error?

    private let lock = NSLock()
    private let codec = PairingCodeCodec()
    private var unpairCallsStorage: [MachineID] = []
    private var confirmedCodesStorage: [String] = []

    public var unpairCalls: [MachineID] {
        lock.withLock { unpairCallsStorage }
    }

    public var confirmedCodes: [String] {
        lock.withLock { confirmedCodesStorage }
    }

    public init(machine: Machine, verificationCode: String = "418942") {
        self.machineToReturn = machine
        self.expectedCode = verificationCode
    }

    public func parseCode(_ raw: String) throws -> PairingOffer {
        try codec.decode(raw)
    }

    public func beginPairing(with offer: PairingOffer) async throws -> PairingHandshake {
        if let beginError { throw beginError }
        let machine = Machine(
            id: MachineID("pending-\(offer.machineName.lowercased().replacingOccurrences(of: " ", with: "-"))"),
            displayName: offer.machineName,
            modelDescription: "Mac",
            status: .online
        )
        return PairingHandshake(offer: offer, verificationCode: expectedCode, machine: machine)
    }

    public func confirm(
        _ handshake: PairingHandshake,
        enteredCode: String
    ) async throws -> PairingResult {
        lock.withLock {
            confirmedCodesStorage.append(enteredCode)
        }

        guard ConstantTimeComparison.equal(enteredCode, handshake.verificationCode) else {
            throw PairingError.verificationCodeMismatch
        }
        if let confirmError { throw confirmError }

        var machine = machineToReturn
        machine.status = .online
        machine.lastSeenAt = Date(timeIntervalSince1970: 1_700_000_000)
        return PairingResult(machine: machine, credential: credential)
    }

    public func unpair(_ machineID: MachineID) async throws {
        lock.withLock {
            unpairCallsStorage.append(machineID)
        }
    }
}

/// Spy scheduler used by previews and tests: records everything scheduled.
public final class RecordingNotificationScheduler: AppNotificationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LocalNotificationDescriptor] = []
    private var cleared: [SessionID] = []

    public var requestAuthorizationResult = true

    public init() {}

    @discardableResult
    public func requestAuthorization() async -> Bool {
        requestAuthorizationResult
    }

    public func schedule(_ descriptor: LocalNotificationDescriptor) async {
        lock.withLock {
            recorded.append(descriptor)
        }
    }

    public func clearNotifications(for sessionID: SessionID) async {
        lock.withLock {
            cleared.append(sessionID)
            recorded.removeAll { $0.sessionID == sessionID }
        }
    }

    public var scheduled: [LocalNotificationDescriptor] {
        lock.withLock { recorded }
    }

    public var clearedSessions: [SessionID] {
        lock.withLock { cleared }
    }
}
