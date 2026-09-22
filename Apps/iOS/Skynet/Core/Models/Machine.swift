import Foundation

/// A paired Mac that runs coding-agent sessions.
///
/// The iOS app never runs an agent itself; every session executes on one of
/// these machines and is streamed back over a relay.
public struct Machine: Identifiable, Hashable, Codable, Sendable {
    public let id: MachineID
    public var displayName: String
    /// Hardware description, e.g. "MacBook Pro (14-inch)".
    public var modelDescription: String
    public var osVersion: String
    public var status: MachineStatus
    public var lastSeenAt: Date?
    public var capabilities: MachineCapabilities

    public init(
        id: MachineID,
        displayName: String,
        modelDescription: String = "Mac",
        osVersion: String = "",
        status: MachineStatus = .offline,
        lastSeenAt: Date? = nil,
        capabilities: MachineCapabilities = MachineCapabilities()
    ) {
        self.id = id
        self.displayName = displayName
        self.modelDescription = modelDescription
        self.osVersion = osVersion
        self.status = status
        self.lastSeenAt = lastSeenAt
        self.capabilities = capabilities
    }
}

public enum MachineStatus: String, Codable, Sendable {
    case online
    case offline

    public var isOnline: Bool { self == .online }
}

/// Optional capabilities advertised by the relay during pairing.
public struct MachineCapabilities: Hashable, Codable, Sendable {
    public var relayProtocolVersion: Int
    public var maxConcurrentSessions: Int
    public var supportsLiveActivities: Bool

    public init(
        relayProtocolVersion: Int = 1,
        maxConcurrentSessions: Int = 1,
        supportsLiveActivities: Bool = false
    ) {
        self.relayProtocolVersion = relayProtocolVersion
        self.maxConcurrentSessions = maxConcurrentSessions
        self.supportsLiveActivities = supportsLiveActivities
    }
}
