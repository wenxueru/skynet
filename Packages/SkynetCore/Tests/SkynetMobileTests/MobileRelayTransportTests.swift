import Foundation
import Network
import Security
import XCTest
@testable import SkynetMobile

final class MobileRelayTransportTests: XCTestCase {
    private let key = Data(repeating: 0x25, count: 32)
    private let token = String(repeating: "synthetic-token-", count: 3)

    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var storedPort: UInt16?
        private var storedRequests = 0
        var port: UInt16? { lock.lock(); defer { lock.unlock() }; return storedPort }
        var requests: Int { lock.lock(); defer { lock.unlock() }; return storedRequests }
        func setPort(_ port: UInt16) { lock.lock(); storedPort = port; lock.unlock() }
        func receivedRequest() { lock.lock(); storedRequests += 1; lock.unlock() }
    }

    private func listening(
        handler: @escaping @Sendable (MobileRelayRequest) async -> MobileRelayReply = { _ in .ok }
    ) async throws -> (MobileRelayListener, URL) {
        let ready = expectation(description: "Loopback listener ready")
        let observations = Observations()
        let listener = try MobileRelayListener(key: key, loopbackOnly: true, handler: handler) { port, error in
            if let port { observations.setPort(port); ready.fulfill() }
            if let error { XCTFail(error); ready.fulfill() }
        }
        listener.start()
        await fulfillment(of: [ready], timeout: 5)
        guard let port = observations.port else {
            listener.stop()
            throw SkynetError.connectionLost("Loopback listener failed to start.")
        }
        return (listener, URL(string: "skynet-relay://127.0.0.1:\(port)")!)
    }

    private func secret(key: Data? = nil, token: String? = nil) -> String {
        (key ?? self.key).base64EncodedString() + "." + (token ?? self.token)
    }

    private func channel(_ endpoint: URL) -> (MobileRelayConnection, NWConnection) {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(endpoint.port!))!,
                                      using: MobileRelaySecret.parameters(key: key))
        return (MobileRelayConnection(connection: connection), connection)
    }

    private func bounded<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw SkynetError.connectionLost("Loopback test timed out.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    func testAuthenticatedLoopbackRoundTrip() async throws {
        let token = self.token
        let (listener, endpoint) = try await listening { request in
            guard request.credential == token else { return .failure("Invalid application token.") }
            return .models([.balanced])
        }
        defer { listener.stop() }
        let (channel, rawConnection) = channel(endpoint)
        defer { channel.close() }
        try await bounded { try await channel.start() }
        let metadata = try XCTUnwrap(rawConnection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata)
        XCTAssertEqual(sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata), .TLSv12)
        XCTAssertEqual(sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue,
                       UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))
        try await channel.send(MobileRelayRequest(credential: token, command: .models))
        let reply = try await bounded { try await channel.receive(MobileRelayReply.self) }
        guard case .models(let models) = reply else { return XCTFail("Expected model catalog.") }
        XCTAssertEqual(models, [.balanced])
    }

    func testWrongTLSKeyCannotReachApplicationHandler() async throws {
        let observations = Observations()
        let (listener, endpoint) = try await listening { _ in observations.receivedRequest(); return .ok }
        defer { listener.stop() }
        do {
            _ = try await MobileRelayConnection.call(endpoint: endpoint,
                secret: secret(key: Data(repeating: 0x39, count: 32)), command: .ping, timeout: .seconds(3))
            XCTFail("A mismatched PSK must not connect.")
        } catch SkynetError.connectionLost(let reason) {
            XCTAssertFalse(reason.contains("did not respond"), "Wrong keys must fail authentication, not merely time out.")
            XCTAssertEqual(observations.requests, 0)
        }
    }

    func testCorrectTLSKeyStillRequiresApplicationToken() async throws {
        let token = self.token
        let (listener, endpoint) = try await listening { request in
            request.credential == token ? .ok : .unauthorized("Invalid application token.")
        }
        defer { listener.stop() }
        do {
            _ = try await MobileRelayConnection.call(endpoint: endpoint,
                secret: secret(token: String(repeating: "wrong-token-", count: 3)), command: .ping,
                timeout: .seconds(5))
            XCTFail("TLS key possession alone must not authorize a request.")
        } catch SkynetError.authorizationFailed(let reason) {
            XCTAssertEqual(reason, "Invalid application token.")
        }
    }

    func testUnsupportedVersionRejectedBeforeHandler() async throws {
        let observations = Observations()
        let (listener, endpoint) = try await listening { _ in observations.receivedRequest(); return .ok }
        defer { listener.stop() }
        let (channel, _) = channel(endpoint)
        defer { channel.close() }
        try await bounded { try await channel.start() }
        var request = MobileRelayRequest(credential: token, command: .ping)
        request.version = 999
        try await channel.send(request)
        let reply = try await bounded { try await channel.receive(MobileRelayReply.self) }
        guard case .failure(let reason) = reply else { return XCTFail("Expected protocol rejection.") }
        XCTAssertEqual(reason, "Unsupported mobile protocol version.")
        XCTAssertEqual(observations.requests, 0)
    }

    func testFrameSizeBounds() throws {
        XCTAssertEqual(try MobileRelayConnection.frameSize(Data([0, 0, 0, 1])), 1)
        XCTAssertEqual(try MobileRelayConnection.frameSize(Data([0, 128, 0, 0])), 8 * 1024 * 1024)
        for header in [Data(), Data([0, 0, 0]), Data([0, 0, 0, 0]), Data([0, 128, 0, 1]), Data(repeating: 255, count: 4)] {
            XCTAssertThrowsError(try MobileRelayConnection.frameSize(header))
        }
    }

    func testOversizedOutgoingMessageRejected() async throws {
        let connection = NWConnection(host: "127.0.0.1", port: 1,
                                      using: MobileRelaySecret.parameters(key: key))
        let channel = MobileRelayConnection(connection: connection)
        defer { channel.close() }
        do {
            try await channel.send(String(repeating: "x", count: MobileRelayConnection.maximumFrameSize))
            XCTFail("JSON encoding overhead must count toward the frame bound.")
        } catch SkynetError.invalidInput(_) { }
    }

    func testCancellationBeforeStartDoesNotHang() async throws {
        let connection = NWConnection(host: "127.0.0.1", port: 1,
                                      using: MobileRelaySecret.parameters(key: key))
        let channel = MobileRelayConnection(connection: connection)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await channel.start()
        }
        do { try await bounded { try await task.value }; XCTFail("Canceled task started a connection.") }
        catch is CancellationError { }
    }

    func testCloseBeforeStartAndListenerStopBeforeStart() async throws {
        let listener = try MobileRelayListener(key: key, loopbackOnly: true, handler: { _ in .ok }) { _, _ in
            XCTFail("A stopped listener must not announce readiness.")
        }
        listener.stop()
        listener.start()
        let connection = NWConnection(host: "127.0.0.1", port: 1,
                                      using: MobileRelaySecret.parameters(key: key))
        let channel = MobileRelayConnection(connection: connection)
        channel.close()
        do { try await bounded { try await channel.start() }; XCTFail("A closed connection must not start.") }
        catch SkynetError.connectionLost(let reason) { XCTAssertNotEqual(reason, "Loopback test timed out.") }
    }

    func testCancelPendingReceiveAndDisconnectDrain() async throws {
        let (listener, endpoint) = try await listening()
        defer { listener.stop() }
        let (channel, _) = channel(endpoint)
        defer { channel.close() }
        try await bounded { try await channel.start() }
        let receive = Task { try await channel.receive(MobileRelayReply.self) }
        try await Task.sleep(for: .milliseconds(100))
        receive.cancel()
        do { _ = try await bounded { try await receive.value }; XCTFail("Canceled receive must fail.") }
        catch is CancellationError { }

        let (second, _) = self.channel(endpoint)
        defer { second.close() }
        try await bounded { try await second.start() }
        let disconnected = Task { try await second.receive(MobileRelayReply.self) }
        listener.stop()
        do { _ = try await bounded { try await disconnected.value }; XCTFail("Listener shutdown must drain pending receive.") }
        catch SkynetError.connectionLost(let reason) { XCTAssertNotEqual(reason, "Loopback test timed out.") }
    }

    func testMalformedIncomingFrameDoesNotReachHandler() async throws {
        let observations = Observations()
        let (listener, endpoint) = try await listening { _ in observations.receivedRequest(); return .ok }
        defer { listener.stop() }
        let (channel, rawConnection) = channel(endpoint)
        defer { channel.close() }
        try await bounded { try await channel.start() }
        try await bounded {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    rawConnection.send(content: Data([255, 255, 255, 255]), completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    })
                }
            } onCancel: { rawConnection.cancel() }
        }
        do {
            _ = try await bounded { try await channel.receive(MobileRelayReply.self) }
            XCTFail("An invalid frame must close the connection.")
        } catch SkynetError.connectionLost(let reason) {
            XCTAssertNotEqual(reason, "Loopback test timed out.")
            XCTAssertEqual(observations.requests, 0)
        }
    }
}
