import Foundation
import Network
import Security

public enum MobileRelayCommand: Codable, Sendable {
    case ping
    case beginPairing
    case confirmPairing(code: String)
    case unpair
    case projects
    case sessions(ProjectID)
    case createSession(ProjectID, AgentConfiguration)
    case rename(SessionID, String)
    case delete(SessionID)
    case models
    case configure(SessionID, AgentConfiguration)
    case snapshot(SessionID)
    case send(SessionID, PromptPayload)
    case cancel(SessionID)
    case permission(SessionID, TranscriptItemID, PermissionDecision)
}

public struct MobileRelayRequest: Codable, Sendable {
    public var version = 1
    public var credential: String
    public var command: MobileRelayCommand
    public init(credential: String, command: MobileRelayCommand) {
        self.credential = credential
        self.command = command
    }
}

public struct MobileSessionSnapshot: Codable, Equatable, Sendable {
    public var session: AgentSession
    public var items: [TranscriptItem]
    public init(session: AgentSession, items: [TranscriptItem]) {
        self.session = session
        self.items = items
    }
}

public enum MobileRelayReply: Codable, Sendable {
    case ok
    case machine(Machine)
    case paired(PairingResult)
    case projects([Project])
    case sessions([AgentSession])
    case session(AgentSession)
    case models([AgentModel])
    case snapshot(MobileSessionSnapshot)
    case unauthorized(String)
    case failure(String)
}

/// The QR invitation and saved credential contain a TLS key followed by a
/// separately revocable application token. Neither is sent over plaintext TCP.
public struct MobileRelaySecret: Sendable {
    public let key: Data
    public let token: String

    public init(_ encoded: String) throws {
        let parts = encoded.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, let key = Data(base64Encoded: String(parts[0])),
              key.count == 32, parts[1].count >= 32 else {
            throw SkynetError.invalidInput("Invalid pairing credential. Pair again.")
        }
        self.key = key
        token = String(parts[1])
    }

    public static func randomToken() throws -> String {
        try randomKey().base64EncodedString()
    }

    public static func randomKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SkynetError.invalidInput("Could not generate a secure pairing key.")
        }
        return Data(bytes)
    }

    public static func parameters(key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        // Network.framework's external PSK support uses this TLS 1.2 AEAD
        // suite, also recommended in Apple's TLS-PSK example. No certificate
        // fallback or permissive verification callback is installed.
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )
        let identity = Data("skynet-mobile-v1".utf8)
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                                               keyData as __DispatchData, identityData as __DispatchData)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        return parameters
    }
}

/// Cancellation and a late Network callback may race. The continuation belongs
/// to this single-completion gate, not to either callback.
private final class RelayOperation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result == nil
    }

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        onFinish()
    }
}

/// Length-prefixed, bounded JSON over authenticated TLS. Each RPC has its own
/// connection, so canceling an observer never cancels a provider turn.
public final class MobileRelayConnection: @unchecked Sendable {
    public static let maximumFrameSize = 8 * 1024 * 1024
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "skynet.mobile.connection")
    // Accessed only on queue, including close-before-start and terminal events.
    private var closed = false
    private var started = false
    private var ready = false
    private var pending: [UUID: (Error) -> Void] = [:]

    public init(connection: NWConnection) { self.connection = connection }

    public func close() {
        queue.async { self.finishConnection(CancellationError()) }
    }

    private func finishConnection(_ error: Error) {
        guard !closed else { return }
        closed = true
        let operations = pending.values
        pending.removeAll()
        operations.forEach { $0(error) }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func perform<Value>(
        _ action: @escaping (RelayOperation<Value>) -> Void
    ) async throws -> Value {
        let id = UUID()
        let operation = RelayOperation<Value> { [weak self] in
            guard let self else { return }
            self.queue.async { self.pending[id] = nil }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                queue.async {
                    guard operation.isPending else { return }
                    guard !self.closed else {
                        operation.finish(.failure(SkynetError.connectionLost("The mobile connection closed.")))
                        return
                    }
                    self.pending[id] = { operation.finish(.failure($0)) }
                    action(operation)
                }
            }
        } onCancel: {
            operation.finish(.failure(CancellationError()))
            self.close()
        }
    }

    public func start() async throws {
        try await perform { (operation: RelayOperation<Void>) in
            if self.ready { operation.finish(.success(())); return }
            guard !self.started else {
                operation.finish(.failure(SkynetError.invalidInput("The mobile connection is already starting.")))
                return
            }
            self.started = true
            self.connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.ready = true
                    operation.finish(.success(()))
                case .waiting(let error), .failed(let error):
                    self.finishConnection(SkynetError.connectionLost("Could not establish the secure mobile connection: \(error)"))
                case .cancelled:
                    self.finishConnection(SkynetError.connectionLost("Could not connect to your Mac."))
                default: break
                }
            }
            self.connection.start(queue: self.queue)
        }
    }

    public func send<T: Encodable>(_ value: T) async throws {
        try Task.checkCancellation()
        let body = try JSONEncoder().encode(value)
        guard body.count <= Self.maximumFrameSize else {
            throw SkynetError.invalidInput("This request is too large for the mobile connection.")
        }
        var size = UInt32(body.count).bigEndian
        let frame = withUnsafeBytes(of: &size) { Data($0) } + body
        try await perform { (operation: RelayOperation<Void>) in
            self.connection.send(content: frame, completion: .contentProcessed { error in
                if error != nil {
                    operation.finish(.failure(SkynetError.connectionLost("The mobile connection closed while sending.")))
                } else { operation.finish(.success(())) }
            })
        }
    }

    public func receive<T: Decodable>(_ type: T.Type) async throws -> T {
        let header = try await readExactly(4)
        let size = try Self.frameSize(header)
        let body = try await readExactly(size)
        return try JSONDecoder().decode(type, from: body)
    }

    static func frameSize(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw SkynetError.invalidInput("Invalid mobile message header.") }
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= Self.maximumFrameSize else {
            throw SkynetError.invalidInput("Invalid mobile message size.")
        }
        return size
    }

    private func readExactly(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            try Task.checkCancellation()
            let remaining = count - result.count
            let chunk: Data = try await perform { operation in
                self.connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, _, error in
                    if error != nil || data?.isEmpty != false {
                        operation.finish(.failure(SkynetError.connectionLost("The mobile connection closed.")))
                    } else { operation.finish(.success(data!)) }
                }
            }
            result.append(chunk)
        }
        return result
    }

    public static func call(endpoint: URL, secret: String, command: MobileRelayCommand,
                            timeout: Duration = .seconds(20)) async throws -> MobileRelayReply {
        guard endpoint.scheme == "skynet-relay", let host = endpoint.host,
              let rawPort = endpoint.port, let port = NWEndpoint.Port(rawValue: UInt16(exactly: rawPort) ?? 0),
              port.rawValue > 0, endpoint.user == nil, endpoint.password == nil else {
            throw SkynetError.invalidInput("Invalid Mac relay address.")
        }
        let credential = try MobileRelaySecret(secret)
        let channel = MobileRelayConnection(connection: NWConnection(
            host: NWEndpoint.Host(host), port: port, using: MobileRelaySecret.parameters(key: credential.key)
        ))
        defer { channel.close() }
        return try await withThrowingTaskGroup(of: MobileRelayReply.self) { group in
            group.addTask {
                try await channel.start()
                try await channel.send(MobileRelayRequest(credential: credential.token, command: command))
                return try await channel.receive(MobileRelayReply.self)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SkynetError.connectionLost("Your Mac did not respond. Check the connection and try again.")
            }
            defer { group.cancelAll(); channel.close() }
            guard let reply = try await group.next() else { throw CancellationError() }
            if case .unauthorized(let reason) = reply { throw SkynetError.authorizationFailed(reason) }
            if case .failure(let reason) = reply { throw SkynetError.relayRejected(reason) }
            return reply
        }
    }
}

/// The listener is opt-in. The handler must authorize every request before
/// touching application data; possessing the shared TLS key is not sufficient.
public final class MobileRelayListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "skynet.mobile.listener")
    private var channels: [UUID: MobileRelayConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false

    public init(key: Data, port: UInt16 = 0, loopbackOnly: Bool = false,
                handler: @escaping @Sendable (MobileRelayRequest) async -> MobileRelayReply,
                state: @escaping @Sendable (UInt16?, String?) -> Void) throws {
        guard key.count == 32 else { throw SkynetError.invalidInput("Invalid mobile TLS key.") }
        let parameters = MobileRelaySecret.parameters(key: key)
        if loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        }
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        listener.stateUpdateHandler = { [weak self] value in
            guard let self, !self.stopped else { return }
            switch value {
            case .ready: state(self.listener.port?.rawValue, nil)
            case .waiting(let error), .failed(let error):
                self.stopOnQueue()
                state(nil, "Could not start the mobile connection service: \(error)")
            case .cancelled: self.stopOnQueue()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped, self.channels.count < 16 else { connection.cancel(); return }
            let id = UUID()
            let channel = MobileRelayConnection(connection: connection)
            self.channels[id] = channel
            self.tasks[id] = Task {
                defer {
                    channel.close()
                    self.queue.async { self.channels[id] = nil; self.tasks[id] = nil }
                }
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await channel.start()
                            let request = try await channel.receive(MobileRelayRequest.self)
                            let reply = request.version == 1 ? await handler(request) : .failure("Unsupported mobile protocol version.")
                            try await channel.send(reply)
                        }
                        group.addTask {
                            try await Task.sleep(for: .seconds(25))
                            throw SkynetError.connectionLost("Mobile request timed out.")
                        }
                        defer { group.cancelAll(); channel.close() }
                        _ = try await group.next()
                    }
                } catch { /* Closed or invalid clients do not affect provider execution. */ }
            }
        }
    }

    public func start() {
        queue.async {
            guard !self.stopped, !self.started else { return }
            self.started = true
            self.listener.start(queue: self.queue)
        }
    }
    public func stop() {
        queue.async { self.stopOnQueue() }
    }

    private var started = false

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        tasks.values.forEach { $0.cancel() }
        channels.values.forEach { $0.close() }
        tasks.removeAll()
        channels.removeAll()
    }
}
