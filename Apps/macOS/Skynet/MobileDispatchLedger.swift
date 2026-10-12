import CryptoKit
import Foundation
import SkynetMobile

/// Durable send identities. Pending receipts stay uncertain after a failed
/// effect or write; they must never be treated as permission to send again.
struct MobileDispatchLedger {
    enum State: String, Codable { case pending, accepted }

    private struct Receipt: Codable {
        var sessionID: String
        var payloadDigest: String
        var state: State
    }

    private var receipts: [String: Receipt] = [:]
    private var loadFailed = false

    init(url: URL?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            receipts = try JSONDecoder().decode([String: Receipt].self, from: Data(contentsOf: url))
        } catch {
            loadFailed = true
        }
    }

    static func digest(_ payload: PromptPayload) throws -> String {
        SHA256.hash(data: try encoder().encode(payload)).map { String(format: "%02x", $0) }.joined()
    }

    func wasAccepted(_ dispatch: String, sessionID: String, digest: String) throws -> Bool {
        guard let previous = receipts[dispatch] else { return false }
        guard previous.sessionID == sessionID, previous.payloadDigest == digest else {
            throw SkynetError.relayRejected("Dispatch identity does not match this message.")
        }
        guard previous.state == .accepted else {
            throw SkynetError.relayRejected("Delivery is uncertain. Check this session on the Mac before sending again.")
        }
        return true
    }

    func writableURL(_ url: URL?) throws -> URL {
        guard !loadFailed, receipts.count < 10000, let url else {
            throw SkynetError.relayRejected("The mobile dispatch ledger is full or unavailable. Send from the Mac.")
        }
        return url
    }

    mutating func persist(_ state: State, dispatch: String, sessionID: String, digest: String, to url: URL) throws {
        var updated = receipts
        updated[dispatch] = Receipt(sessionID: sessionID, payloadDigest: digest, state: state)
        try Self.encoder().encode(updated).write(to: url, options: .atomic)
        receipts = updated
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}
