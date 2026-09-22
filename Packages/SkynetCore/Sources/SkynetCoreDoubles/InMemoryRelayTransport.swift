import Foundation
import SkynetCore

/// A `RelayTransport` that loops back to a `ScriptedExecutionBackend`.
///
/// Lets iOS-shaped code paths (relay-only) be exercised on the test host
/// without any network: `RelayBackend` → `InMemoryRelayTransport` →
/// `LoopbackRelayChannel` → scripted process output.
public final class InMemoryRelayTransport: RelayTransport, @unchecked Sendable {
    /// The single channel every connection returns. Launched requests are
    /// visible through `channel.backend`.
    public let channel: LoopbackRelayChannel

    private let lock = NSLock()
    private var connectionCountValue = 0
    private var lastPairingValue: PairingRecord?
    private var connectErrorValue: Error?

    public init(scripts: [ScriptedExecutionBackend.Script] = []) {
        self.channel = LoopbackRelayChannel(scripts: scripts)
    }

    /// How many times `connect` succeeded.
    public var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connectionCountValue
    }

    /// The pairing the last connection was asked to reach.
    public var lastPairing: PairingRecord? {
        lock.lock()
        defer { lock.unlock() }
        return lastPairingValue
    }

    /// When set, `connect` throws this — for testing unreachable-relay
    /// handling.
    public var connectError: Error? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return connectErrorValue
        }
        set {
            lock.lock()
            connectErrorValue = newValue
            lock.unlock()
        }
    }

    public func connect(to pairing: PairingRecord) throws -> any RelayChannel {
        lock.lock()
        let error = connectErrorValue
        lastPairingValue = pairing
        lock.unlock()
        if let error {
            throw error
        }
        lock.lock()
        connectionCountValue += 1
        lock.unlock()
        return channel
    }

    /// One scripted relay channel: launches land on a nested scripted
    /// backend, so `channel.backend.launchedRequests` shows exactly what
    /// the relay was asked to run.
    public final class LoopbackRelayChannel: RelayChannel, @unchecked Sendable {
        public let backend: ScriptedExecutionBackend

        init(scripts: [ScriptedExecutionBackend.Script]) {
            self.backend = ScriptedExecutionBackend(
                id: BackendID("relay-scripted"),
                displayName: "Loopback relay",
                kind: .relay,
                scripts: scripts
            )
        }

        public func launch(_ request: ExecutionRequest) throws -> any ExecutionProcess {
            try backend.launch(request)
        }

        public func close() {}
    }
}
