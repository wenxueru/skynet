import Foundation

/// The persisted result of pairing this device with a Mac relay.
///
/// Pairing itself (key exchange, QR/handshake UX) belongs to the app layer
/// and the relay server; the core only records *that* a Mac is paired and
/// what a transport needs to reach it. `relayKeyFingerprint` pins the Mac's
/// long-term identity key so every later connection verifies it.
public struct PairingRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var host: String
    public var port: Int
    /// The Mac's user-facing name ("Wenxue's MacBook Pro").
    public var macName: String
    /// SHA-256 fingerprint (hex) of the relay's identity key.
    public var relayKeyFingerprint: String?
    /// Opaque token issued at pairing time; the transport presents it to
    /// authenticate this device.
    public var pairingToken: String?
    public var createdAt: Date
    public var lastConnectedAt: Date?

    public init(
        id: String = UUID().uuidString,
        host: String,
        port: Int,
        macName: String,
        relayKeyFingerprint: String? = nil,
        pairingToken: String? = nil,
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.macName = macName
        self.relayKeyFingerprint = relayKeyFingerprint
        self.pairingToken = pairingToken
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }
}

/// One live connection to a paired Mac relay.
///
/// Implementations (the real relay protocol lives outside SkynetCore, and
/// `InMemoryRelayTransport` in SkynetCoreDoubles is the test one) speak
/// some encrypted framing; the core only cares that a channel can launch
/// processes that behave like local ones.
public protocol RelayChannel: Sendable {
    /// Launches a process on the Mac side. The returned process streams
    /// the Mac's stdout/stderr and forwards stdin.
    func launch(_ request: ExecutionRequest) async throws -> any ExecutionProcess
    /// Closes the channel and every process launched through it.
    func close() async
}

/// Establishes `RelayChannel`s to paired Macs.
public protocol RelayTransport: Sendable {
    /// Connects (or returns a cached connection) to the paired relay.
    /// Throws `SkynetError.relayUnreachable` when the Mac cannot be
    /// reached and `SkynetError.relayNotPaired` semantics are handled by
    /// `RelayBackend` before this is called.
    func connect(to pairing: PairingRecord) async throws -> any RelayChannel
}

/// An `ExecutionBackend` that forwards every launch to a paired Mac over
/// an encrypted relay. This is the only backend that exists on iOS.
public struct RelayBackend: ExecutionBackend {
    public var id: BackendID
    public var displayName: String
    public let kind: ExecutionBackendKind = .relay
    public var pairing: PairingRecord?
    public let transport: any RelayTransport

    public init(
        id: BackendID = BackendID("relay"),
        displayName: String = "Paired Mac",
        pairing: PairingRecord?,
        transport: any RelayTransport
    ) {
        self.id = id
        self.displayName = displayName
        self.pairing = pairing
        self.transport = transport
    }

    public func launch(_ request: ExecutionRequest) async throws -> any ExecutionProcess {
        guard let pairing else {
            throw SkynetError.relayNotPaired
        }
        let channel: any RelayChannel
        do {
            channel = try await transport.connect(to: pairing)
        } catch let error as SkynetError {
            throw error
        } catch {
            throw SkynetError.relayUnreachable(detail: String(describing: error))
        }
        do {
            return try await channel.launch(request)
        } catch let error as SkynetError {
            throw error
        } catch {
            throw SkynetError.relayUnreachable(detail: String(describing: error))
        }
    }
}
