import Foundation

/// One agent conversation scoped to a project on a machine.
public struct AgentSession: Identifiable, Hashable, Codable, Sendable {
    public let id: SessionID
    public var projectID: ProjectID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var state: TurnState
    /// One-line preview of the latest exchange, used in session lists.
    public var lastPreview: String
    public var unreadCount: Int
    public var configuration: AgentConfiguration

    public init(
        id: SessionID,
        projectID: ProjectID,
        title: String,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date = Date(timeIntervalSince1970: 0),
        state: TurnState = .idle,
        lastPreview: String = "",
        unreadCount: Int = 0,
        configuration: AgentConfiguration = .standard
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.lastPreview = lastPreview
        self.unreadCount = unreadCount
        self.configuration = configuration
    }
}

/// Lifecycle of the agent's current turn.
public enum TurnState: String, Codable, Hashable, Sendable {
    case idle
    case running
    case awaitingPermission
    case canceling
    case failed

    /// True while the agent is actively working through a turn.
    public var isBusy: Bool {
        switch self {
        case .idle: return false
        case .running, .awaitingPermission, .canceling, .failed: return true
        }
    }

    /// Whether a new prompt can be sent immediately.
    public var acceptsNewPrompt: Bool { self == .idle }

    /// User-facing label for badges and menus.
    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .awaitingPermission: return "Awaiting approval"
        case .canceling: return "Canceling"
        case .failed: return "Failed"
        }
    }
}
