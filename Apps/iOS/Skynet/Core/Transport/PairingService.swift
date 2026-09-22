import Foundation

/// A one-time pairing invitation rendered as a QR code (or copied as text)
/// by the Mac that wants to be paired.
public struct PairingOffer: Equatable, Codable, Sendable {
    /// Where the relay for this machine listens.
    public var relayEndpoint: URL
    /// Human-readable machine name to confirm against.
    public var machineName: String
    /// Opaque one-time token from the Mac.
    public var token: String
    public var expiresAt: Date?

    public init(
        relayEndpoint: URL,
        machineName: String,
        token: String,
        expiresAt: Date? = nil
    ) {
        self.relayEndpoint = relayEndpoint
        self.machineName = machineName
        self.token = token
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

/// The in-progress state after an offer is accepted by the relay.
public struct PairingHandshake: Equatable, Sendable {
    public var offer: PairingOffer
    /// Six digits shown on the Mac; the user confirms they match.
    public var verificationCode: String
    /// Provisional machine record revealed during handshake.
    public var machine: Machine

    public init(offer: PairingOffer, verificationCode: String, machine: Machine) {
        self.offer = offer
        self.verificationCode = verificationCode
        self.machine = machine
    }
}

/// Errors specific to the pairing flow.
public enum PairingError: Error, Equatable, Sendable {
    /// The scanned or typed string is not a valid pairing code.
    case invalidCode
    /// The code was structurally valid but has expired.
    case expired
    /// The relay refused the offer (wrong token, already paired, …).
    case rejected(String)
    /// The user-entered code did not match the handshake's code.
    case verificationCodeMismatch
    /// The transport failed mid-handshake.
    case transportFailed(String)
}

/// Result of a successful pairing: the machine record plus the long-lived
/// credential the app must persist.
public struct PairingResult: Equatable, Sendable {
    public let machine: Machine
    public let credential: MachineCredential

    public init(machine: Machine, credential: MachineCredential) {
        self.machine = machine
        self.credential = credential
    }
}

/// Drives the secure pairing flow:
///
/// 1. Read a `PairingOffer` from a QR code or pasted text.
/// 2. `beginPairing` asks the relay to open a handshake; the Mac shows a
///    six-digit verification code derived from the pairing keys.
/// 3. The user types what they see on the Mac; `confirm` verifies it matches
///    and — only on a match — the relay issues a long-lived credential.
/// 4. The credential is stored via `PairedMachineStore` (Keychain in
///    production).
///
/// Implementations own the actual key exchange; this protocol keeps the UI and
/// tests independent of it.
public protocol PairingService: Sendable {
    /// Parses a scanned or pasted pairing string.
    func parseCode(_ raw: String) throws -> PairingOffer

    /// Opens a handshake for an offer.
    func beginPairing(with offer: PairingOffer) async throws -> PairingHandshake

    /// Confirms the user saw the same verification code as the Mac.
    /// Throws `PairingError.verificationCodeMismatch` on a bad code.
    func confirm(
        _ handshake: PairingHandshake,
        enteredCode: String
    ) async throws -> PairingResult

    /// Breaks the association with a machine, revoking credentials.
    func unpair(_ machineID: MachineID) async throws
}

/// Encodes and decodes `PairingOffer` values to compact, copy-pasteable
/// strings shared via QR code.
///
/// Format: `skynet-pair://pair?v=1&m=<name>&e=<base64url endpoint>&t=<token>`
/// (`x` carries an optional expiry timestamp).
public struct PairingCodeCodec: Sendable {
    public static let scheme = "skynet-pair"
    private static let version = 1

    public init() {}

    public func encode(_ offer: PairingOffer) -> String {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "v", value: String(Self.version)),
            URLQueryItem(name: "m", value: offer.machineName),
            URLQueryItem(name: "e", value: Self.base64URLEncode(offer.relayEndpoint.absoluteString)),
            URLQueryItem(name: "t", value: offer.token),
        ]
        if let expiresAt = offer.expiresAt {
            items.append(URLQueryItem(name: "x", value: String(Int(expiresAt.timeIntervalSince1970))))
        }
        components.queryItems = items
        return components.url?.absoluteString ?? ""
    }

    public func decode(_ raw: String) throws -> PairingOffer {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme,
              let query = components.queryItems else {
            throw PairingError.invalidCode
        }

        func value(for name: String) -> String? {
            query.first(where: { $0.name == name })?.value
        }

        guard let version = value(for: "v"), version == String(Self.version),
              let encodedEndpoint = value(for: "e"),
              let endpointString = Self.base64URLDecode(encodedEndpoint),
              let endpoint = URL(string: endpointString),
              let token = value(for: "t"), !token.isEmpty else {
            throw PairingError.invalidCode
        }

        let machineName = value(for: "m") ?? "Mac"
        var expiresAt: Date?
        if let rawExpiry = value(for: "x"), let seconds = TimeInterval(rawExpiry) {
            expiresAt = Date(timeIntervalSince1970: seconds)
        }

        return PairingOffer(
            relayEndpoint: endpoint,
            machineName: machineName,
            token: token,
            expiresAt: expiresAt
        )
    }

    // MARK: Base64url

    private static func base64URLEncode(_ string: String) -> String {
        Data(string.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ string: String) -> String? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Constant-time string comparison for verification codes, so timing never
/// leaks how many leading digits matched.
public enum ConstantTimeComparison {
    public static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var diff: UInt8 = a.count == b.count ? 0 : 1
        let count = max(a.count, b.count)
        for index in 0..<count {
            let byteA = index < a.count ? a[index] : 0
            let byteB = index < b.count ? b[index] : 0
            diff |= byteA ^ byteB
        }
        return diff == 0
    }
}
