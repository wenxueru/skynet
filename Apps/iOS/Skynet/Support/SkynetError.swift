import Foundation

/// Unified error surface for the app. Transport implementations map their
/// native errors into these.
public enum SkynetError: Error, Equatable, Sendable {
    /// No Mac is paired or the configured relay is not reachable yet.
    case notPaired
    /// The relay link went down mid-request.
    case connectionLost(String)
    /// The relay answered with a failure.
    case relayRejected(String)
    /// A stored pairing is missing its credential.
    case missingCredential(MachineID)
    /// Keychain interaction failed.
    case keychainFailure(OSStatus)
    /// Local validation failed (empty prompt, bad rename, …).
    case invalidInput(String)

    public var isConnectivityRelated: Bool {
        switch self {
        case .notPaired, .connectionLost: return true
        case .relayRejected, .missingCredential, .keychainFailure, .invalidInput: return false
        }
    }
}

extension SkynetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notPaired:
            return "Pair a Mac to get started."
        case .connectionLost(let detail):
            return detail.isEmpty ? "Connection to the Mac was lost." : detail
        case .relayRejected(let detail):
            return detail
        case .missingCredential(let machineID):
            return "The saved credential for “\(machineID.rawValue)” is missing. Pair again."
        case .keychainFailure(let status):
            return "Keychain error (\(status))."
        case .invalidInput(let detail):
            return detail
        }
    }
}
