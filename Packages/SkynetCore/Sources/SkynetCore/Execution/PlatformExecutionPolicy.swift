import Foundation

/// Runtime statement of the process boundary:
///
/// - **macOS** may run agent CLIs locally (spawned directly) or via SSH.
/// - **iOS** may not spawn processes at all — its only route to an agent is
///   a paired Mac reached through the relay.
///
/// The boundary is enforced twice. Compile-time: the `LocalProcessBackend`
/// and `SSHBackend` *types* do not exist outside macOS, so an iOS target
/// cannot even name them. Runtime: every launch passes through
/// `assertCanLaunch(on:)`, which also rejects a mis-tagged backend (e.g. a
/// relay that claims to be local) no matter which platform it runs on.
public struct PlatformExecutionPolicy: Hashable, Sendable {
    /// The platform this policy speaks for, for error messages.
    public var platformName: String
    public var allowsLocalProcesses: Bool
    public var allowsSSH: Bool
    public var allowsRelay: Bool

    public init(
        platformName: String,
        allowsLocalProcesses: Bool,
        allowsSSH: Bool,
        allowsRelay: Bool
    ) {
        self.platformName = platformName
        self.allowsLocalProcesses = allowsLocalProcesses
        self.allowsSSH = allowsSSH
        self.allowsRelay = allowsRelay
    }

    /// Full access: local processes, SSH, relay.
    public static let macOS = PlatformExecutionPolicy(
        platformName: "macOS",
        allowsLocalProcesses: true,
        allowsSSH: true,
        allowsRelay: true
    )

    /// Relay-only: no process spawning of any kind on this device.
    public static let iOS = PlatformExecutionPolicy(
        platformName: "iOS",
        allowsLocalProcesses: false,
        allowsSSH: false,
        allowsRelay: true
    )

    /// The policy for the platform this code compiled for.
    public static let current: PlatformExecutionPolicy = {
        #if os(macOS)
        return .macOS
        #elseif os(iOS)
        return .iOS
        #else
        // Unknown platform: be conservative and allow relay only.
        return PlatformExecutionPolicy(
            platformName: "this platform",
            allowsLocalProcesses: false,
            allowsSSH: false,
            allowsRelay: true
        )
        #endif
    }()

    /// Throws `SkynetError.unsupportedOnPlatform` when the backend's kind
    /// is not allowed. Call before every launch.
    public func assertCanLaunch(on backend: any ExecutionBackend, operation: String) throws {
        let allowed: Bool
        switch backend.kind {
        case .local: allowed = allowsLocalProcesses
        case .ssh: allowed = allowsSSH
        case .relay: allowed = allowsRelay
        }
        guard allowed else {
            throw SkynetError.unsupportedOnPlatform(
                operation: operation,
                platform: platformName
            )
        }
    }
}
