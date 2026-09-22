import Foundation
import SwiftUI

/// Destinations pushed onto the compact-width navigation stack.
public enum AppDestination: Hashable {
    case project(Project)
    case session(AgentSession)
}

/// Single navigation authority for both size classes:
///
/// - Compact (iPhone): `compactPath` drives a `NavigationStack`.
/// - Regular (iPad): `selectedProject` / `selectedSession` drive the
///   `NavigationSplitView` columns.
///
/// Mutations update both representations at once so rotating a device or
/// changing size class keeps the user's place. Session values hash by ID, so
/// pushing an updated snapshot of the same session does not create a new
/// stack entry.
@MainActor
@Observable
public final class AppRouter {
    public var compactPath = NavigationPath()
    public var selectedProject: Project?
    public var selectedSession: AgentSession?

    public init() {}

    public func open(project: Project) {
        selectedProject = project
        selectedSession = nil
        compactPath.append(AppDestination.project(project))
    }

    public func open(session: AgentSession) {
        selectedProject = projectFor(session) ?? selectedProject
        selectedSession = session
        compactPath.append(AppDestination.session(session))
    }

    /// Replaces the current detail session (used when a session's metadata
    /// refreshes) without stacking another entry.
    public func refreshSelected(session: AgentSession) {
        guard let current = selectedSession, current.id == session.id else { return }
        selectedSession = session
    }

    public func popToRoot() {
        selectedSession = nil
        selectedProject = nil
        compactPath = NavigationPath()
    }

    /// Drops the detail session and rebuilds the stack up to the project list.
    public func popToProjectList() {
        selectedSession = nil
        var rebuilt = NavigationPath()
        if let selectedProject {
            rebuilt.append(AppDestination.project(selectedProject))
        }
        compactPath = rebuilt
    }

    private func projectFor(_ session: AgentSession) -> Project? {
        selectedProject?.id == session.projectID ? selectedProject : nil
    }
}
