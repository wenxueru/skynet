import Foundation
import SkynetCore

/// Sidebar projections only. Does not mutate records or own session selection.
enum SessionLibraryQuery {
    static func projects(_ projects: [Project], sessions: [SessionRecord], query: String) -> [Project] {
        var occupied: Set<ProjectID> = []
        var matchingSessions: Set<ProjectID> = []
        for session in sessions {
            guard let projectID = session.projectID else { continue }
            if session.isArchived != true { occupied.insert(projectID) }
            if !query.isEmpty, sessionMatches(session, query: query) {
                matchingSessions.insert(projectID)
            }
        }
        var pinned: [Project] = []
        var other: [Project] = []
        for project in projects {
            let isPinned = project.metadata["pinned"] == "true"
            guard project.metadata["discovered"] != "true" || isPinned
                    || occupied.contains(project.id) else { continue }
            guard query.isEmpty || projectMatches(project, query: query)
                    || matchingSessions.contains(project.id) else { continue }
            if isPinned { pinned.append(project) }
            else { other.append(project) }
        }
        return pinned + other
    }

    static func sessions(_ sessions: [SessionRecord], in project: Project, query: String) -> [SessionRecord] {
        let visible = sessions.filter { $0.projectID == project.id && $0.isArchived != true }
            .sorted { lhs, rhs in
                if (lhs.pinMode != nil) != (rhs.pinMode != nil) { return lhs.pinMode != nil }
                return lhs.updatedAt > rhs.updatedAt
            }
        guard !query.isEmpty, !projectMatches(project, query: query) else { return visible }
        return visible.filter { sessionMatches($0, query: query) }
    }

    private static func projectMatches(_ project: Project, query: String) -> Bool {
        project.name.localizedCaseInsensitiveContains(query)
            || (project.rootPath?.localizedCaseInsensitiveContains(query) ?? false)
    }

    private static func sessionMatches(_ session: SessionRecord, query: String) -> Bool {
        (session.title ?? "New session").localizedCaseInsensitiveContains(query)
    }
}
