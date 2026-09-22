import Foundation

/// The error surface of SkynetCore.
public enum SkynetError: Error, Sendable, Hashable {
    /// An entity referenced by ID does not exist.
    case notFound(what: String, id: String)
    /// A user-configured provider failed validation.
    case invalidProviderConfiguration(detail: String)
    /// The provider cannot carry an attachment the turn asked for.
    case attachmentUnsupported(provider: String, reason: String)
    /// The requested operation is not available on this platform.
    ///
    /// Enforced by `PlatformExecutionPolicy` — most notably, iOS cannot spawn
    /// local processes and must go through a paired Mac relay.
    case unsupportedOnPlatform(operation: String, platform: String)
    /// The execution backend refused or failed to launch a process.
    case executionFailed(reason: String)
    /// The agent process exited with a non-zero status.
    case agentExited(code: Int32, stderr: String)
    /// The agent violated its protocol (malformed output, missing fields).
    case protocolViolation(detail: String)
    /// A persisted record is newer than (or incompatible with) this build.
    case unsupportedStoreSchema(found: Int, supported: Int)
    /// Reading or writing the persistent store failed.
    case persistenceFailure(underlying: String)
    /// A tool call was denied by the permission policy.
    case permissionDenied(tool: String, reason: String)
    /// The operation timed out.
    case timedOut(after: TimeInterval)
    /// A relay is not paired, or the pairing was rejected.
    case relayNotPaired
    /// The relay connection failed or was severed mid-operation.
    case relayUnreachable(detail: String)
}

extension SkynetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let what, let id):
            return "\(what) with id \(id) was not found"
        case .invalidProviderConfiguration(let detail):
            return "Invalid provider configuration: \(detail)"
        case .attachmentUnsupported(let provider, let reason):
            return "\(provider) cannot use this attachment: \(reason)"
        case .unsupportedOnPlatform(let operation, let platform):
            return "\(operation) is not supported on \(platform)"
        case .executionFailed(let reason):
            return "Execution failed: \(reason)"
        case .agentExited(let code, let stderr):
            let detail = stderr.isEmpty ? "" : ": \(stderr)"
            return "Agent process exited with code \(code)\(detail)"
        case .protocolViolation(let detail):
            return "Agent protocol violation: \(detail)"
        case .unsupportedStoreSchema(let found, let supported):
            return "Store schema \(found) is not supported (this build understands \(supported))"
        case .persistenceFailure(let underlying):
            return "Persistence failure: \(underlying)"
        case .permissionDenied(let tool, let reason):
            return "Tool \(tool) was denied: \(reason)"
        case .timedOut(let after):
            return "The operation timed out after \(after) seconds"
        case .relayNotPaired:
            return "No Mac relay is paired with this device"
        case .relayUnreachable(let detail):
            return "The Mac relay is unreachable: \(detail)"
        }
    }
}
