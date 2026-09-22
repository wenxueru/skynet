import Foundation

/// Drives the session list for one project: loading, search filtering,
/// creation, rename, and deletion. Also keeps the app-wide `SessionIndex`
/// fresh so notification taps can deep link without refetching.
@MainActor
@Observable
public final class SessionListViewModel {
    public let project: Project

    public var sessions: [AgentSession] = []
    public var searchQuery = ""
    public private(set) var isLoading = false
    public private(set) var loadError: String?
    public private(set) var isCreatingSession = false

    private let relay: any SkynetRelay
    private let router: AppRouter
    private let sessionIndex: SessionIndex

    public init(
        project: Project,
        relay: any SkynetRelay,
        router: AppRouter,
        sessionIndex: SessionIndex
    ) {
        self.project = project
        self.relay = relay
        self.router = router
        self.sessionIndex = sessionIndex
    }

    // MARK: - Loading

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = try await relay
                .sessions(in: project.id)
                .sorted { $0.updatedAt > $1.updatedAt }
            await sessionIndex.register(sessions: sessions)
            loadError = nil
        } catch {
            loadError = "Couldn't load sessions. \(error.localizedDescription)"
        }
    }

    public var filteredSessions: [AgentSession] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.lastPreview.localizedCaseInsensitiveContains(query)
        }
    }

    public var hasEmptySearchResults: Bool {
        !searchQuery.isEmpty && filteredSessions.isEmpty
    }

    // MARK: - Creation

    public func createSession() async {
        guard !isCreatingSession else { return }
        isCreatingSession = true
        defer { isCreatingSession = false }
        do {
            let session = try await relay.createSession(
                in: project.id,
                configuration: .standard
            )
            sessions.insert(session, at: 0)
            await sessionIndex.register(sessions: [session])
            loadError = nil
            router.open(session: session)
        } catch {
            loadError = "Couldn't create a session. \(error.localizedDescription)"
        }
    }

    // MARK: - Rename

    public func rename(_ session: AgentSession, to newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != session.title else { return }
        do {
            try await relay.renameSession(session.id, to: trimmed)
            applyTitle(trimmed, to: session.id)
            if var updated = sessions.first(where: { $0.id == session.id }) {
                updated.title = trimmed
                await sessionIndex.register(sessions: [updated])
                router.refreshSelected(session: updated)
            }
        } catch {
            loadError = "Couldn't rename the session. \(error.localizedDescription)"
        }
    }

    // MARK: - Deletion

    public func delete(_ session: AgentSession) async {
        do {
            try await relay.deleteSession(session.id)
        } catch {
            loadError = "Couldn't delete the session. \(error.localizedDescription)"
            return
        }
        sessions.removeAll { $0.id == session.id }
        await sessionIndex.remove(session: session.id)
        if router.selectedSession?.id == session.id {
            router.popToProjectList()
        }
    }

    // MARK: - Helpers

    private func applyTitle(_ title: String, to sessionID: SessionID) {
        for index in sessions.indices where sessions[index].id == sessionID {
            sessions[index].title = title
            sessions[index].updatedAt = Date()
        }
    }
}
