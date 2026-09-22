import Foundation

/// Lightweight app-wide index of known sessions and projects, kept fresh as
/// lists load. Powers deep links (notification taps) without touching the
/// relay again.
public actor SessionIndex {
    private var sessionsByID: [SessionID: AgentSession] = [:]
    private var projectsByID: [ProjectID: Project] = [:]

    public init() {}

    public func register(sessions: [AgentSession]) {
        for session in sessions {
            sessionsByID[session.id] = session
        }
    }

    public func register(projects: [Project]) {
        for project in projects {
            projectsByID[project.id] = project
        }
    }

    public func lookup(session id: SessionID) -> AgentSession? {
        sessionsByID[id]
    }

    public func project(for id: ProjectID) -> Project? {
        projectsByID[id]
    }

    public func remove(session id: SessionID) {
        sessionsByID[id] = nil
    }

    public var sessionCount: Int { sessionsByID.count }
}
