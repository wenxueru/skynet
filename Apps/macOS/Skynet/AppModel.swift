import AppKit
import Foundation
import Observation
import SkynetCore

@MainActor
@Observable
final class AppModel {
    struct QueuedPrompt: Codable, Identifiable {
        var id = UUID()
        var text: String
        var attachments: [ImageAttachment]
        var createdAt = Date()
        var scheduledAt: Date? = nil
        /// A persisted dispatch marker prevents an uncertain send from being replayed.
        var dispatchStartedAt: Date? = nil
    }

    struct ComposerDraft: Codable {
        var text: String
        var attachments: [ImageAttachment]
    }

    struct LiveTool: Identifiable {
        var id: ToolCallID
        var name: String
        var input: JSONValue
        var output: String?
        var isError = false
    }

    private struct TranscriptLoadResult: Sendable {
        let messages: [Message]
        let olderCursor: Int64?
        let errorMessage: String?
    }

    private enum TranscriptCursor {
        case provider(Int64)
        case cache(Int64)
    }

    private struct TranscriptMessageKey: Hashable {
        let origin: String
        let createdAt: Date
        let content: [ContentBlock]
    }

    var projects: [Project] = []
    var sessions: [SessionRecord] = []
    var providers: [AgentProviderDescriptor] = AgentProviderDescriptor.builtIns
    var selectedProjectID: ProjectID?
    var selectedSessionID: SessionID?
    var messages: [Message] = [] {
        didSet { transcriptGroups = TranscriptGrouping.groups(messages) }
    }
    private(set) var transcriptGroups: [TranscriptGroup] = []
    var liveText = ""
    var liveThinking = ""
    var liveTools: [LiveTool] = []
    var searchText = ""
    var isRunning = false
    var isSelectedSessionRunning: Bool {
        isRunning && selectedSessionID == activeTurnSessionID
    }
    var hasSelectedSessionActivity: Bool {
        selectedSessionID != nil && selectedSessionID == liveSessionID
    }
    var workingSince: Date?
    var errorMessage: String?
    var pendingAttachments: [ImageAttachment] = []
    var queuedPrompts: [QueuedPrompt] = []
    private(set) var steeringQueuedPromptID: UUID?
    var canSteerQueuedPrompt: Bool {
        isSelectedSessionRunning && steeringQueuedPromptID == nil
    }
    var scheduledDispatchingSessionID: SessionID? { scheduledDispatchSessionID }
    var pendingPermissionRequest: PermissionRequest?
    var pendingPermissionSessionTitle: String?
    var machines: [DiscoveredMachine] = [.local]
    var disabledMachineIDs: Set<BackendID>
    private var deletedDiscoveryKeys: Set<DiscoverySessionKey>
    var machineErrors: [BackendID: String] = [:]
    var isDiscovering = false
    var isLoadingTranscript = false
    var isLoadingOlderTranscript: Bool {
        selectedSessionID != nil && loadingOlderTranscriptSessionID == selectedSessionID
    }
    private(set) var storageDirectoryURL: URL?

    private let store: JSONDiskStore?
    private var activeSession: AgentSession?
    private var activeTurnSessionID: SessionID?
    private var liveSessionID: SessionID?
    private var streamTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    private var loadingOlderTranscriptSessionID: SessionID?
    private var permissionContinuation: CheckedContinuation<PermissionResponse, Never>?
    private var scheduleTimer: Task<Void, Never>?
    private var scheduledDispatch: Task<Void, Never>?
    private var scheduledDispatchSessionID: SessionID?
    private var scheduledQueueSessionIDs: Set<SessionID> = []
    private var transcriptCursors: [SessionID: TranscriptCursor] = [:]
    private var transcriptCacheCursors: [SessionID: Int64] = [:]
    private var transcriptLoadToken = UUID()

    private static let disabledMachinesKey = "disabledMachineIDs"
    private static let deletedDiscoveryKeysKey = "deletedDiscoveryKeys"

    init() {
        disabledMachineIDs = Set(
            (UserDefaults.standard.stringArray(forKey: Self.disabledMachinesKey) ?? [])
                .map { BackendID($0) }
        )
        deletedDiscoveryKeys = UserDefaults.standard.data(forKey: Self.deletedDiscoveryKeysKey)
            .flatMap { try? JSONDecoder().decode(Set<DiscoverySessionKey>.self, from: $0) }
            ?? []
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let storageURL = base.appendingPathComponent("Skynet", isDirectory: true)
            storageDirectoryURL = storageURL
            store = try JSONDiskStore(rootURL: storageURL)
            load()
            refreshDiscovery()
            scheduleTimer = Task { [weak self] in
                while !Task.isCancelled {
                    self?.deliverMatureScheduledMessage()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        } catch {
            store = nil
            errorMessage = "Unable to initialize Skynet storage: \(error.localizedDescription)"
        }
    }

    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedSession: SessionRecord? {
        sessions.first { $0.id == selectedSessionID }
    }

    var canLoadOlderTranscript: Bool {
        selectedSessionID.flatMap { transcriptCursors[$0] } != nil
    }

    var selectedProvider: AgentProviderDescriptor? {
        guard let selectedSession else { return nil }
        return providers.first { $0.id == selectedSession.providerID }
    }

    var visibleMachines: [DiscoveredMachine] {
        machines.filter { !disabledMachineIDs.contains($0.id) }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var filteredProjects: [Project] {
        let query = normalizedSearchText
        let visibleProjects = projects.filter { project in
            guard project.metadata["discovered"] == "true",
                  project.metadata["pinned"] != "true" else { return true }
            return sessions.contains {
                $0.projectID == project.id && $0.isArchived != true
            }
        }
        let matching = query.isEmpty ? visibleProjects : visibleProjects.filter { project in
            projectMatchesSearch(project, query: query)
                || sessions.contains {
                    $0.projectID == project.id && sessionMatchesSearch($0, query: query)
                }
        }
        return matching.filter { $0.metadata["pinned"] == "true" }
            + matching.filter { $0.metadata["pinned"] != "true" }
    }

    func sessions(for project: Project) -> [SessionRecord] {
        sessions.filter { $0.projectID == project.id }
    }

    func filteredSessions(for project: Project) -> [SessionRecord] {
        let query = normalizedSearchText
        let projectSessions = sessions(for: project)
            .filter { $0.isArchived != true }
            .sorted { lhs, rhs in
                if (lhs.pinMode != nil) != (rhs.pinMode != nil) {
                    return lhs.pinMode != nil
                }
                return lhs.updatedAt > rhs.updatedAt
            }
        guard !query.isEmpty, !projectMatchesSearch(project, query: query) else {
            return projectSessions
        }
        return projectSessions.filter { sessionMatchesSearch($0, query: query) }
    }

    func filteredProjects(for machine: DiscoveredMachine) -> [Project] {
        filteredProjects.filter { backendID(for: $0) == machine.id }
    }

    func backendID(for project: Project) -> BackendID {
        BackendID(project.metadata["backendID"] ?? "local")
    }

    func refreshDiscovery() {
        guard !isDiscovering else { return }
        isDiscovering = true
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            let snapshots = await MacSessionDiscovery.discover(excluding: self.disabledMachineIDs)
            guard !Task.isCancelled else { return }
            do {
                try mergeDiscovery(snapshots)
            } catch {
                errorMessage = error.localizedDescription
            }
            isDiscovering = false
            discoveryTask = nil
        }
    }

    func load() {
        guard let store else { return }
        do {
            projects = try store.loadProjects().sorted { $0.updatedAt > $1.updatedAt }
            sessions = try store.loadSessions(matching: nil)
            recoverInterruptedLocalSessions(in: &sessions, store: store)
            scheduledQueueSessionIDs = Set(sessions.compactMap { session in
                queueEntries(for: session.id).contains(where: {
                    $0.scheduledAt != nil && $0.dispatchStartedAt == nil
                }) ? session.id : nil
            })
            providers = try ProviderCatalog.effective(
                userConfigured: store.loadUserProviders()
            ).providers
            if selectedProjectID == nil { selectedProjectID = projects.first?.id }
            if selectedSessionID == nil, let project = selectedProject {
                selectedSessionID = sessions(for: project).first?.id
            }
            if let selectedSessionID {
                loadQueue(for: selectedSessionID)
                loadTranscript(for: selectedSessionID, includeProviderHistory: false)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func recoverInterruptedLocalSessions(
        in sessions: inout [SessionRecord],
        store: JSONDiskStore
    ) {
        for index in sessions.indices where
            sessions[index].status == .running
                && sessions[index].backendID == DiscoveredMachine.local.id {
            // Local agent processes are children of Skynet; they cannot still
            // be running after a fresh app launch.
            sessions[index].status = .idle
            do {
                try store.saveSession(sessions[index])
            } catch {
                errorMessage = "Could not clear an interrupted session state: \(error.localizedDescription)"
            }
        }
    }

    func addProject(url: URL) {
        let standardized = url.standardizedFileURL.path
        if let existing = projects.first(where: {
            $0.rootPath == standardized && backendID(for: $0) == DiscoveredMachine.local.id
        }) {
            select(project: existing)
            return
        }
        let project = Project(
            name: url.lastPathComponent,
            rootPath: standardized,
            metadata: ["backendID": DiscoveredMachine.local.id.rawValue]
        )
        projects.insert(project, at: 0)
        do {
            let store = try requireStore()
            try store.saveProjects(projects)
            select(project: project)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(project: Project) {
        selectedProjectID = project.id
        if let first = filteredSessions(for: project).first {
            select(session: first)
        } else {
            clearSessionSelection()
        }
    }

    func select(session: SessionRecord) {
        let isChangingSession = selectedSessionID != session.id
        selectedProjectID = session.projectID
        selectedSessionID = session.id
        if isChangingSession { messages = [] }
        loadQueue(for: session.id)
        if session.markedUnreadAt != nil {
            var updated = session
            updated.markedUnreadAt = nil
            save(updated)
        }
        if !isRunning { resetLiveState() }
        loadTranscript(for: session.id)
    }

    func setSessionPinMode(_ session: SessionRecord, mode: SessionRecord.PinMode?) {
        var updated = session
        updated.pinMode = mode
        save(updated)
    }

    func markSessionUnread(_ session: SessionRecord) {
        var updated = session
        updated.markedUnreadAt = Date()
        save(updated)
    }

    func forkSession(_ source: SessionRecord) async {
        guard !(isRunning && selectedSessionID == source.id),
              source.status != .running else {
            errorMessage = "Stop the session before forking it."
            return
        }
        guard let sourceID = source.providerResumeToken else {
            errorMessage = "This session has no original conversation to fork."
            return
        }
        do {
            let store = try requireStore()
            let provider = providers.first { $0.id == source.providerID }
            let messages = try await Task.detached(priority: .userInitiated) {
                try store.loadMessages(for: source.id)
            }.value
            var child = source
            child.id = SessionID()
            child.title = "\(source.title ?? "Session") (fork)"
            child.createdAt = Date()
            child.updatedAt = child.createdAt
            child.status = .idle
            child.totalUsage = TokenUsage()
            child.isArchived = nil
            child.archivedInProvider = nil
            child.pinMode = nil
            child.markedUnreadAt = nil
            switch provider?.kind {
            case .codex:
                child.providerResumeToken = try await CodexThreadFork.fork(
                    threadID: sourceID,
                    backend: executionBackend(for: source),
                    executable: provider?.resolvedExecutableName ?? "codex",
                    environment: provider?.environment ?? [:]
                )
                child.forkSourceToken = nil
            case .claudeCode:
                child.providerResumeToken = nil
                child.forkSourceToken = sourceID
            case .claudeCodeCompatible, nil:
                throw SkynetError.executionFailed(
                    reason: "Forking is not verified for this provider."
                )
            }
            try store.replaceMessages(messages, for: child.id)
            try store.saveSession(child)
            sessions.insert(child, at: 0)
            select(session: child)
        } catch {
            errorMessage = "Fork failed: \(error.localizedDescription)"
        }
    }

    func exportSession(_ session: SessionRecord, format: SessionTranscriptExport.Format) {
        Task {
            do {
                let store = try requireStore()
                let messages = try await Task.detached(priority: .userInitiated) {
                    try store.loadMessages(for: session.id)
                }.value
                let data = try SessionTranscriptExport.data(
                    session: session, messages: messages, format: format
                )
                let panel = NSSavePanel()
                let safeTitle = (session.title ?? "session")
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                panel.nameFieldStringValue = "\(safeTitle).\(format.fileExtension)"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
            } catch {
                errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func clearSessionSelection() {
        transcriptLoadToken = UUID()
        selectedSessionID = nil
        transcriptTask?.cancel()
        transcriptTask = nil
        messages = []
        queuedPrompts = []
        isLoadingTranscript = false
        resetLiveState()
    }

    @discardableResult
    func deleteSessions(_ ids: Set<SessionID>) async -> Set<SessionID> {
        var deleted: Set<SessionID> = []
        var failures: [String] = []
        let targets = sessions.filter { ids.contains($0.id) }
        let titlesByID = Dictionary(uniqueKeysWithValues: targets.map {
            ($0.id, $0.title ?? "Session")
        })
        var deletable: [SessionRecord] = []
        for session in targets {
            if (isRunning && selectedSessionID == session.id)
                || scheduledDispatchSessionID == session.id {
                failures.append("Stop \(session.title ?? "the running session") before deleting it.")
                continue
            }
            deletable.append(session)
        }

        // Provider-owned deletions each launch a CLI/app-server process. Run a
        // small number concurrently so multi-select doesn't pay the full
        // startup latency once per session (or overwhelm remote backends).
        let maxConcurrentDeletions = 4
        let results = await withTaskGroup(of: (SessionID, String?).self) { group in
            var nextTarget = deletable.makeIterator()
            for _ in 0..<min(maxConcurrentDeletions, deletable.count) {
                guard let session = nextTarget.next() else { break }
                group.addTask { await self.deleteProviderSession(session) }
            }

            var results: [(SessionID, String?)] = []
            while let result = await group.next() {
                results.append(result)
                if let session = nextTarget.next() {
                    group.addTask { await self.deleteProviderSession(session) }
                }
            }
            return results
        }
        for (id, failure) in results {
            if let failure {
                failures.append("\(titlesByID[id] ?? "Session"): \(failure)")
            } else {
                deleted.insert(id)
            }
        }

        if !deleted.isEmpty && !removeCachedSessions(deleted) {
            failures.append("The original session was deleted, but its Skynet cache could not be removed.")
            deleted.removeAll()
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        return deleted
    }

    private func deleteProviderSession(_ session: SessionRecord) async -> (SessionID, String?) {
        do {
            if let sourceID = session.providerResumeToken {
                let provider = providers.first { $0.id == session.providerID }
                switch provider?.kind {
                case .codex:
                    try await CodexThreadDelete.delete(
                        threadID: sourceID,
                        backend: executionBackend(for: session),
                        executable: provider?.resolvedExecutableName ?? "codex",
                        environment: provider?.environment ?? [:]
                    )
                case .claudeCode, .claudeCodeCompatible:
                    try await ClaudeSessionDelete.delete(
                        sessionID: sourceID,
                        backend: executionBackend(for: session),
                        environment: provider?.environment ?? [:]
                    )
                case nil:
                    throw SkynetError.executionFailed(reason: "The session provider is unavailable.")
                }
            } else if session.messageCount > 0 {
                throw SkynetError.executionFailed(reason: "No original session ID is available.")
            }
            return (session.id, nil)
        } catch {
            return (session.id, error.localizedDescription)
        }
    }

    @discardableResult
    private func removeCachedSessions(_ ids: Set<SessionID>) -> Bool {
        guard !ids.isEmpty else { return true }
        if isRunning, let selectedSessionID, ids.contains(selectedSessionID) {
            errorMessage = "Stop the running session before deleting it."
            return false
        }
        if let scheduledDispatchSessionID, ids.contains(scheduledDispatchSessionID) {
            errorMessage = "Wait for the scheduled message to finish before deleting this session."
            return false
        }
        do {
            let store = try requireStore()
            let deleted = sessions.filter { ids.contains($0.id) }
            for id in ids {
                try store.deleteSession(id: id)
            }
            let remainingSessions = sessions.filter { !ids.contains($0.id) }
            let affectedProjects = Set(deleted.compactMap(\.projectID))
            let occupiedProjects = Set(remainingSessions.compactMap(\.projectID))
            let remainingProjects = projects.filter {
                !affectedProjects.contains($0.id) || occupiedProjects.contains($0.id)
            }
            if remainingProjects.count != projects.count {
                try store.saveProjects(remainingProjects)
            }

            deletedDiscoveryKeys.formUnion(deleted.compactMap { session in
                guard session.providerResumeToken != nil else { return nil }
                return DiscoverySessionKey(session: session)
            })
            UserDefaults.standard.set(
                try JSONEncoder().encode(deletedDiscoveryKeys),
                forKey: Self.deletedDiscoveryKeysKey
            )

            sessions = remainingSessions
            projects = remainingProjects
            if let selectedProjectID, !projects.contains(where: { $0.id == selectedProjectID }) {
                self.selectedProjectID = nil
            }
            if let selectedSessionID, ids.contains(selectedSessionID) {
                clearSessionSelection()
            }
            for id in ids {
                if let url = scratchlistURL(for: id) { try? FileManager.default.removeItem(at: url) }
                if let url = queueURL(for: id) { try? FileManager.default.removeItem(at: url) }
                if let url = composerDraftURL(for: id) { try? FileManager.default.removeItem(at: url) }
            }
            scheduledQueueSessionIDs.subtract(ids)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setProjectPinned(_ project: Project, pinned: Bool) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].metadata["pinned"] = pinned ? "true" : nil
        projects[index].updatedAt = Date()
        persistProjects()
    }

    func renameProject(_ project: Project, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].name = trimmed
        projects[index].updatedAt = Date()
        persistProjects()
    }

    @discardableResult
    func setProjectChatsArchived(_ project: Project, archived: Bool) async -> Set<SessionID> {
        let ids = Set(sessions(for: project)
            .filter { ($0.isArchived == true) != archived }
            .map(\.id))
        return await setSessionsArchived(ids, archived: archived)
    }

    @discardableResult
    func setSessionsArchived(_ ids: Set<SessionID>, archived: Bool) async -> Set<SessionID> {
        guard let store else { return [] }
        var changed: Set<SessionID> = []
        var failures: [String] = []
        for session in sessions where ids.contains(session.id) {
            if isRunning && selectedSessionID == session.id {
                failures.append("Stop \(session.title ?? "the running session") before changing its archive state.")
                continue
            }
            do {
                if archived && session.providerID != .codex {
                    throw SkynetError.executionFailed(
                        reason: "Claude Code CLI does not expose a native session archive operation."
                    )
                }
                if session.providerID == .codex && (archived || session.archivedInProvider == true) {
                    guard let threadID = session.providerResumeToken else {
                        throw SkynetError.executionFailed(
                            reason: "This Codex session has no provider thread to archive."
                        )
                    }
                    let provider = providers.first { $0.id == .codex }
                    try await CodexThreadArchive.setArchived(
                        archived,
                        threadID: threadID,
                        backend: executionBackend(for: session),
                        executable: provider?.resolvedExecutableName ?? "codex",
                        environment: provider?.environment ?? [:]
                    )
                }
                guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { continue }
                var updated = sessions[index]
                updated.isArchived = archived
                if updated.providerID == .codex {
                    updated.archivedInProvider = archived ? true : nil
                }
                try store.saveSession(updated)
                sessions[index] = updated
                changed.insert(session.id)
            } catch {
                failures.append("\(session.title ?? "Session"): \(error.localizedDescription)")
            }
        }
        if archived, let selectedSessionID, changed.contains(selectedSessionID) {
            clearSessionSelection()
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        return changed
    }

    func openProjectInVSCode(_ project: Project) {
        guard let arguments = VSCodeProjectOpen.arguments(
            rootPath: project.rootPath, backendID: backendID(for: project)
        ) else {
            errorMessage = "This project has no directory to open in VS Code."
            return
        }
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    process.arguments = arguments
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus == 0
                        ? nil : "Visual Studio Code could not open this project."
                } catch {
                    return "Visual Studio Code could not open this project: \(error.localizedDescription)"
                }
            }.value
            if let failure { errorMessage = failure }
        }
    }

    func removeProject(_ project: Project) {
        let ids = Set(sessions(for: project).map(\.id))
        if isRunning, let selectedSessionID, ids.contains(selectedSessionID) {
            errorMessage = "Stop the running session before removing its project."
            return
        }
        if let scheduledDispatchSessionID, ids.contains(scheduledDispatchSessionID) {
            errorMessage = "Wait for the scheduled message to finish before removing its project."
            return
        }
        guard removeCachedSessions(ids) else { return }
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects.remove(at: index)
        persistProjects()
        if selectedProjectID == project.id { selectedProjectID = nil }
    }

    private func persistProjects() {
        do { try requireStore().saveProjects(projects) }
        catch { errorMessage = error.localizedDescription }
    }

    func isMachineEnabled(_ id: BackendID) -> Bool {
        !disabledMachineIDs.contains(id)
    }

    func setMachine(_ id: BackendID, enabled: Bool) {
        if enabled {
            disabledMachineIDs.remove(id)
        } else {
            disabledMachineIDs.insert(id)
            machineErrors[id] = nil
            if selectedSession?.backendID == id {
                clearSessionSelection()
            }
        }
        UserDefaults.standard.set(
            disabledMachineIDs.map(\.rawValue).sorted(),
            forKey: Self.disabledMachinesKey
        )
        if isDiscovering {
            discoveryTask?.cancel()
            discoveryTask = nil
            isDiscovering = false
        }
        refreshDiscovery()
    }

    func createSession(provider: AgentProviderDescriptor) {
        guard let project = selectedProject else {
            errorMessage = "Create or select a project first."
            return
        }
        createSession(provider: provider, in: project)
    }

    func createSession(provider: AgentProviderDescriptor, in project: Project) {
        let record = SessionRecord(
            projectID: project.id,
            providerID: provider.id,
            modelID: nil,
            effort: nil,
            claudePermissionMode: provider.kind == .claudeCode
                || provider.kind == .claudeCodeCompatible ? .manual : nil,
            title: nil,
            backendID: backendID(for: project),
            workingDirectory: project.rootPath
        )
        do {
            let store = try requireStore()
            try store.saveSession(record)
            sessions.insert(record, at: 0)
            select(session: record)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameSelectedSession(_ title: String) {
        guard var session = selectedSession else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, session.title != trimmed else { return }
        let previousTitle = session.title
        session.title = trimmed
        session.updatedAt = Date()
        save(session)
        guard session.providerID == .codex,
              let threadID = session.providerResumeToken else { return }
        let renamedSession = session
        let provider = providers.first { $0.id == .codex }
        Task {
            do {
                try await CodexThreadName.setName(
                    trimmed,
                    threadID: threadID,
                    backend: executionBackend(for: renamedSession),
                    executable: provider?.resolvedExecutableName ?? "codex",
                    environment: provider?.environment ?? [:]
                )
            } catch {
                if var current = sessions.first(where: { $0.id == renamedSession.id }),
                   current.title == trimmed {
                    current.title = previousTitle
                    save(current)
                }
                errorMessage = "Could not rename the original Codex thread: \(error.localizedDescription)"
            }
        }
    }

    func updateModel(_ modelID: ModelID?) {
        guard var session = selectedSession else { return }
        guard session.modelID != modelID else { return }
        session.modelID = modelID
        session.effort = nil
        save(session)
    }

    func updateEffort(_ effort: ReasoningEffort?) {
        guard var session = selectedSession else { return }
        session.effort = effort
        save(session)
    }

    func updatePermissionEffect(_ effect: PermissionRule.Effect) {
        guard var session = selectedSession else { return }
        session.permissionEffect = effect
        save(session)
    }

    func updateCodexApprovalMode(_ mode: SessionRecord.CodexApprovalMode) {
        guard var session = selectedSession else { return }
        session.codexApprovalMode = mode
        session.permissionEffect = .ask
        save(session)
    }

    func updateCodexFastMode(_ enabled: Bool) {
        guard var session = selectedSession else { return }
        session.codexFastMode = enabled
        save(session)
    }

    func updateClaudePermissionMode(_ mode: SessionRecord.ClaudePermissionMode) {
        guard var session = selectedSession else { return }
        session.claudePermissionMode = mode
        session.permissionEffect = .ask
        save(session)
    }

    func answerPermission(_ decision: PermissionResponse.Decision) {
        guard let request = pendingPermissionRequest else { return }
        permissionContinuation?.resume(
            returning: PermissionResponse(requestID: request.id, decision: decision)
        )
        permissionContinuation = nil
        pendingPermissionRequest = nil
        pendingPermissionSessionTitle = nil
    }

    func attachImage(url: URL) {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            let mediaType: String
            switch url.pathExtension.lowercased() {
            case "jpg", "jpeg": mediaType = "image/jpeg"
            case "gif": mediaType = "image/gif"
            case "webp": mediaType = "image/webp"
            default: mediaType = "image/png"
            }
            attachImage(data: data, mediaType: mediaType, fileName: url.lastPathComponent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func attachImage(data: Data, mediaType: String, fileName: String? = nil) {
        pendingAttachments.append(
            ImageAttachment(data: data, mediaType: mediaType, fileName: fileName)
        )
    }

    func imageData(for attachment: ImageAttachment) -> Data? {
        switch attachment.payload {
        case .inline(let data, _): data
        case .blob(let reference): try? store?.loadBlob(reference)
        }
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func moveAttachment(_ id: UUID, by offset: Int) {
        guard let index = pendingAttachments.firstIndex(where: { $0.id == id }),
              pendingAttachments.indices.contains(index + offset) else { return }
        pendingAttachments.swapAt(index, index + offset)
    }

    func enqueueDraft(_ text: String, scheduledAt: Date? = nil) -> Bool {
        guard let sessionID = selectedSessionID else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pendingAttachments.isEmpty else { return false }
        if let scheduledAt {
            guard scheduledAt > Date(), scheduledAt <= Date().addingTimeInterval(7 * 86_400) else {
                errorMessage = "Scheduled time must be within the next 7 days."
                return false
            }
            guard pendingAttachments.isEmpty else {
                errorMessage = "Scheduled messages cannot include images."
                return false
            }
        }
        guard queuedPrompts.count < 100 else {
            errorMessage = "Message queue is full (100 entries)."
            return false
        }
        do {
            let entry = QueuedPrompt(
                text: trimmed, attachments: try storedAttachments(pendingAttachments),
                scheduledAt: scheduledAt
            )
            var updated = queuedPrompts
            updated.append(entry)
            try persistQueue(updated, for: sessionID)
            queuedPrompts = updated
            pendingAttachments = []
            if scheduledAt == nil, !isRunning { sendNextQueued(for: sessionID) }
            return true
        } catch {
            errorMessage = "Could not queue message: \(error.localizedDescription)"
            return false
        }
    }

    func removeQueuedPrompt(_ id: UUID) {
        guard let sessionID = selectedSessionID else { return }
        guard !(scheduledDispatchSessionID == sessionID
            && queuedPrompts.contains(where: { $0.id == id && $0.dispatchStartedAt != nil })) else {
            errorMessage = "This scheduled message is currently sending."
            return
        }
        removeQueuedPrompt(id, for: sessionID)
    }

    func moveQueuedPrompt(_ id: UUID, by offset: Int) {
        guard let sessionID = selectedSessionID,
              let (source, destination) = queuedPromptMoveIndices(for: id, by: offset) else { return }
        var updated = queuedPrompts
        updated.swapAt(source, destination)
        do {
            try persistQueue(updated, for: sessionID)
            queuedPrompts = updated
        } catch {
            errorMessage = "Could not reorder queue: \(error.localizedDescription)"
        }
    }

    func canMoveQueuedPrompt(_ id: UUID, by offset: Int) -> Bool {
        queuedPromptMoveIndices(for: id, by: offset) != nil
    }

    private func queuedPromptMoveIndices(for id: UUID, by offset: Int) -> (Int, Int)? {
        guard let source = queuedPrompts.firstIndex(where: { $0.id == id }) else { return nil }
        let destination = source + offset
        guard queuedPrompts.indices.contains(destination),
              canReorder(queuedPrompts[source]), canReorder(queuedPrompts[destination]) else {
            return nil
        }
        return (source, destination)
    }

    func steerQueuedPrompt(_ id: UUID) {
        guard canSteerQueuedPrompt, let sessionID = selectedSessionID,
              let index = queuedPrompts.firstIndex(where: { $0.id == id }),
              canReorder(queuedPrompts[index]) else { return }
        let entry = queuedPrompts[index]
        if index > 0 {
            var updated = queuedPrompts
            updated.remove(at: index)
            updated.insert(entry, at: 0)
            do {
                try persistQueue(updated, for: sessionID)
                queuedPrompts = updated
            } catch {
                errorMessage = "Could not prioritize queued message: \(error.localizedDescription)"
                return
            }
        }
        steeringQueuedPromptID = id
        cancel()
    }

    private func canReorder(_ entry: QueuedPrompt) -> Bool {
        entry.scheduledAt == nil && entry.dispatchStartedAt == nil
    }

    func takeQueuedPrompt(_ id: UUID) -> QueuedPrompt? {
        guard let sessionID = selectedSessionID,
              let entry = queuedPrompts.first(where: { $0.id == id }) else { return nil }
        guard !(entry.dispatchStartedAt != nil && scheduledDispatchSessionID == sessionID) else {
            errorMessage = "This scheduled message is currently sending."
            return nil
        }
        let updated = queuedPrompts.filter { $0.id != id }
        do {
            try persistQueue(updated, for: sessionID)
            queuedPrompts = updated
            return entry
        } catch {
            errorMessage = "Could not edit queued message: \(error.localizedDescription)"
            return nil
        }
    }

    private func removeQueuedPrompt(_ id: UUID, for sessionID: SessionID) {
        let current = selectedSessionID == sessionID
            ? queuedPrompts
            : queueEntries(for: sessionID)
        let updated = current.filter { $0.id != id }
        do {
            try persistQueue(updated, for: sessionID)
            if selectedSessionID == sessionID { queuedPrompts = updated }
        } catch {
            errorMessage = "Could not update queue: \(error.localizedDescription)"
        }
    }

    private func storedAttachments(_ attachments: [ImageAttachment]) throws -> [ImageAttachment] {
        try attachments.map { attachment in
            var stored = attachment
            if case .inline(let data, let mediaType) = stored.payload {
                guard let store else { throw CocoaError(.fileNoSuchFile) }
                stored.payload = .blob(try store.storeBlob(
                    data, mediaType: mediaType, fileName: stored.fileName
                ))
            }
            return stored
        }
    }

    func saveComposerDraft(_ text: String, attachments: [ImageAttachment], for sessionID: SessionID) {
        guard let url = composerDraftURL(for: sessionID) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let draft = ComposerDraft(text: text, attachments: try storedAttachments(attachments))
            try JSONEncoder().encode(draft).write(to: url, options: .atomic)
        } catch {
            errorMessage = "Could not save composer draft: \(error.localizedDescription)"
        }
    }

    func loadComposerDraft(for sessionID: SessionID) -> ComposerDraft? {
        guard let url = composerDraftURL(for: sessionID),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ComposerDraft.self, from: data)
    }

    private func composerDraftURL(for sessionID: SessionID) -> URL? {
        storageDirectoryURL?
            .appendingPathComponent("composer-drafts", isDirectory: true)
            .appendingPathComponent("\(sessionID.value.uuidString).json")
    }

    private func queueURL(for sessionID: SessionID) -> URL? {
        storageDirectoryURL?
            .appendingPathComponent("message-queues", isDirectory: true)
            .appendingPathComponent("\(sessionID.value.uuidString).json")
    }

    private func loadQueue(for sessionID: SessionID) {
        queuedPrompts = queueEntries(for: sessionID)
    }

    private func queueEntries(for sessionID: SessionID) -> [QueuedPrompt] {
        guard let url = queueURL(for: sessionID),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([QueuedPrompt].self, from: data) else {
            return []
        }
        return Array(entries.prefix(100))
    }

    private func persistQueue(_ entries: [QueuedPrompt], for sessionID: SessionID) throws {
        guard let url = queueURL(for: sessionID) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        if entries.contains(where: { $0.scheduledAt != nil && $0.dispatchStartedAt == nil }) {
            scheduledQueueSessionIDs.insert(sessionID)
        } else {
            scheduledQueueSessionIDs.remove(sessionID)
        }
    }

    func sendNextQueued(for sessionID: SessionID) {
        guard !isRunning, scheduledDispatchSessionID != sessionID,
              selectedSessionID == sessionID,
              let entry = queuedPrompts.first(where: {
                  $0.scheduledAt == nil && $0.dispatchStartedAt == nil
              }) else { return }
        sendQueuedPrompt(entry, for: sessionID)
    }

    private func sendQueuedPrompt(_ entry: QueuedPrompt, for sessionID: SessionID) {
        guard selectedSessionID == sessionID else { return }
        let composerAttachments = pendingAttachments
        pendingAttachments = entry.attachments
        send(entry.text, queuedEntry: entry)
        pendingAttachments.insert(contentsOf: composerAttachments, at: 0)
    }

    private func deliverMatureScheduledMessage() {
        guard scheduledDispatch == nil, !isRunning, let store else { return }
        let now = Date()
        let due = sessions.compactMap { record -> (SessionRecord, QueuedPrompt)? in
            guard scheduledQueueSessionIDs.contains(record.id) else { return nil }
            guard !(selectedSessionID == record.id && isRunning), record.status != .running,
                  let entry = queueEntries(for: record.id).first(where: {
                      ($0.scheduledAt ?? .distantFuture) <= now && $0.dispatchStartedAt == nil
                  }) else { return nil }
            return (record, entry)
        }.min { ($0.1.scheduledAt ?? .distantFuture) < ($1.1.scheduledAt ?? .distantFuture) }
        guard let (record, entry) = due,
              let provider = providers.first(where: { $0.id == record.providerID }) else { return }
        scheduledDispatchSessionID = record.id
        scheduledDispatch = Task { [weak self] in
            guard let self else { return }
            defer {
                scheduledDispatch = nil
                scheduledDispatchSessionID = nil
                deliverMatureScheduledMessage()
            }
            do {
                var queue = queueEntries(for: record.id)
                guard let index = queue.firstIndex(where: { $0.id == entry.id }) else { return }
                queue[index].dispatchStartedAt = Date()
                try persistQueue(queue, for: record.id)
                if selectedSessionID == record.id { queuedPrompts = queue }

                let agent = try AgentSession(
                    record: record,
                    configuration: .init(
                        provider: provider,
                        backend: executionBackend(for: record),
                        permissions: PermissionPolicy(defaultEffect: record.permissionEffect ?? .ask),
                        permissionResponder: AppPermissionResponder { [weak self] request in
                            guard let self else {
                                return PermissionResponse(requestID: request.id, decision: .deny)
                            }
                            return await self.requestPermission(
                                request, sessionTitle: record.title ?? "Scheduled session"
                            )
                        },
                        store: store
                    )
                )
                try await agent.loadPersistedTranscript()
                let stream = try await agent.send(entry.text)
                for try await _ in stream {}
                removeQueuedPrompt(entry.id, for: record.id)
                var updated = await agent.record
                if selectedSessionID != record.id { updated.markedUnreadAt = Date() }
                try store.saveSession(updated)
                replace(updated)
                if selectedSessionID == record.id { loadTranscript(for: record.id) }
            } catch {
                errorMessage = "Scheduled message needs review: \(error.localizedDescription)"
            }
        }
    }

    private func scratchlistURL(for sessionID: SessionID) -> URL? {
        storageDirectoryURL?
            .appendingPathComponent("scratchlists", isDirectory: true)
            .appendingPathComponent("\(sessionID.value.uuidString).json")
    }

    func send(_ prompt: String, queuedEntry: QueuedPrompt? = nil) {
        guard !isRunning, let store, let record = selectedSession,
              let provider = providers.first(where: { $0.id == record.providerID }) else { return }
        guard scheduledDispatchSessionID != record.id else {
            errorMessage = "A scheduled message is already sending in this session."
            return
        }
        let attachments = pendingAttachments
        let referenceSessions = sessions
        pendingAttachments = []
        resetLiveState(for: record.id)
        isRunning = true
        activeTurnSessionID = record.id
        workingSince = Date()
        errorMessage = nil

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            var didStartTurn = false
            var completedTurn = false
            defer {
                isRunning = false
                activeTurnSessionID = nil
                workingSince = nil
                activeSession = nil
                streamTask = nil
                let steeredID = steeringQueuedPromptID
                steeringQueuedPromptID = nil
                if let steeredID,
                   !completedTurn,
                   let entry = queueEntries(for: record.id).first(where: { $0.id == steeredID }) {
                    sendQueuedPrompt(entry, for: record.id)
                } else if completedTurn {
                    sendNextQueued(for: record.id)
                }
            }
            do {
                let session = try AgentSession(
                    record: record,
                    configuration: .init(
                        provider: provider,
                        backend: executionBackend(for: record),
                        permissions: PermissionPolicy(
                            defaultEffect: record.permissionEffect ?? .ask
                        ),
                        permissionResponder: record.codexApprovalMode == .manual
                            || ((provider.kind == .claudeCode || provider.kind == .claudeCodeCompatible)
                                && record.claudePermissionMode == .manual)
                            || (provider.kind != .codex && record.claudePermissionMode == nil
                                && record.permissionEffect == .ask)
                            ? AppPermissionResponder { [weak self] request in
                                guard let self else {
                                    return PermissionResponse(
                                        requestID: request.id,
                                        decision: .deny,
                                        reason: "The session is no longer available."
                                    )
                                }
                                return await self.requestPermission(request)
                            }
                            : nil,
                        store: store
                    )
                )
                activeSession = session
                try await session.loadPersistedTranscript()
                let expandedPrompt = await Task.detached(priority: .userInitiated) {
                    SessionReferenceContext.expand(prompt, sessions: referenceSessions) { id in
                        try? store.loadMessages(for: id)
                    }
                }.value
                let stream = try await session.send(expandedPrompt, attachments: attachments)
                didStartTurn = true
                if let queuedEntry { removeQueuedPrompt(queuedEntry.id, for: record.id) }
                for try await event in stream {
                    apply(event, sessionID: record.id)
                }
                let updated = await session.record
                replace(updated)
                completedTurn = true
            } catch {
                if !(error is CancellationError), steeringQueuedPromptID == nil {
                    errorMessage = error.localizedDescription
                }
                if !didStartTurn {
                    if queuedEntry == nil {
                        pendingAttachments.insert(contentsOf: attachments, at: 0)
                    }
                }
            }
        }
    }

    func cancel() {
        answerPermission(.deny)
        Task { await activeSession?.cancelActiveTurn() }
    }

    func saveCustomProvider(
        name: String,
        executable: String,
        arguments: String
    ) {
        let slug = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let descriptor = AgentProviderDescriptor(
            id: ProviderID(slug.isEmpty ? UUID().uuidString.lowercased() : slug),
            kind: .claudeCodeCompatible,
            displayName: name,
            executable: executable,
            defaultArguments: arguments.split(separator: " ").map(String.init)
        )
        do {
            let store = try requireStore()
            try descriptor.validate()
            var configured = try store.loadUserProviders()
            configured.removeAll { $0.id == descriptor.id }
            configured.append(descriptor)
            try store.saveUserProviders(configured)
            providers = try ProviderCatalog.effective(userConfigured: configured).providers
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteCustomProvider(_ id: ProviderID) {
        guard id != .codex, id != .claudeCode else { return }
        do {
            let store = try requireStore()
            var configured = try store.loadUserProviders()
            configured.removeAll { $0.id == id }
            try store.saveUserProviders(configured)
            providers = try ProviderCatalog.effective(userConfigured: configured).providers
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ event: AgentEvent, sessionID: SessionID) {
        switch event {
        case .textDelta(let text): liveText += text
        case .thinkingDelta(let text): liveThinking += text
        case .messageCompleted(let message):
            guard selectedSessionID == sessionID else { return }
            if !messages.contains(where: { $0.id == message.id }) { messages.append(message) }
        case .toolCallStarted(let call):
            liveTools.append(LiveTool(id: call.id, name: call.name, input: call.input))
        case .toolCallCompleted(let result):
            if let index = liveTools.firstIndex(where: { $0.id == result.toolCallID }) {
                liveTools[index].output = result.content
                liveTools[index].isError = result.isError
            }
        case .turnFailed(let failure): errorMessage = failure.error.localizedDescription
        default: break
        }
    }

    private func save(_ session: SessionRecord) {
        do {
            let store = try requireStore()
            try store.saveSession(session)
            replace(session)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func replace(_ session: SessionRecord) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
    }

    private func projectMatchesSearch(_ project: Project, query: String) -> Bool {
        project.name.localizedCaseInsensitiveContains(query)
            || (project.rootPath?.localizedCaseInsensitiveContains(query) ?? false)
    }

    private func sessionMatchesSearch(_ session: SessionRecord, query: String) -> Bool {
        (session.title ?? "New session").localizedCaseInsensitiveContains(query)
    }

    private func mergeDiscovery(_ snapshots: [MachineSessionSnapshot]) throws {
        guard let store else { return }
        machines = snapshots.map(\.machine)
        machineErrors = Dictionary(
            uniqueKeysWithValues: snapshots.compactMap { snapshot in
                snapshot.error.map { (snapshot.machine.id, $0) }
            }
        )

        var sessionIndexes: [DiscoverySessionKey: Int] = [:]
        for (index, session) in sessions.enumerated() {
            let key = DiscoverySessionKey(session: session)
            if sessionIndexes[key] == nil { sessionIndexes[key] = index }
        }
        for snapshot in snapshots {
            for discovered in snapshot.sessions {
                let key = DiscoverySessionKey(
                    backendID: snapshot.machine.id,
                    providerID: discovered.providerID,
                    resumeToken: discovered.providerSessionID
                )
                guard !deletedDiscoveryKeys.contains(key) else { continue }
                let project = project(
                    for: discovered.workingDirectory,
                    backendID: snapshot.machine.id
                )
                let existingIndex = sessionIndexes[key]
                var record = existingIndex.map { sessions[$0] } ?? SessionRecord(
                    projectID: project.id,
                    providerID: discovered.providerID,
                    modelID: discovered.modelID,
                    title: discovered.title,
                    backendID: snapshot.machine.id,
                    workingDirectory: discovered.workingDirectory,
                    createdAt: discovered.createdAt,
                    updatedAt: discovered.updatedAt,
                    providerResumeToken: discovered.providerSessionID
                )
                let previousUpdatedAt = record.updatedAt
                let previousMessageCount = record.messageCount
                record.projectID = project.id
                record.modelID = record.modelID ?? discovered.modelID
                record.backendID = snapshot.machine.id
                record.workingDirectory = discovered.workingDirectory
                record.providerResumeToken = discovered.providerSessionID
                record.updatedAt = max(record.updatedAt, discovered.updatedAt)
                if discovered.totalUsage.totalTokens != nil {
                    record.totalUsage = discovered.totalUsage
                }
                if record.title == nil { record.title = discovered.title }
                let isRemote = snapshot.machine.id != DiscoveredMachine.local.id
                let shouldReplaceMessages = existingIndex == nil
                    || (isRemote
                        ? discovered.messages.count > record.messageCount
                        : record.messageCount != discovered.messages.count
                            || previousUpdatedAt < discovered.updatedAt)
                if existingIndex != nil,
                   selectedSessionID != record.id,
                   discovered.messages.count > previousMessageCount,
                   discovered.messages.dropFirst(previousMessageCount).contains(where: {
                       $0.origin == .agent && !$0.plainText.isEmpty
                   }) {
                    record.markedUnreadAt = discovered.updatedAt
                }
                var needsImageUpgrade = false
                if !shouldReplaceMessages,
                   discovered.messages.contains(where: Self.containsImage) {
                    needsImageUpgrade = !(try store.loadMessages(for: record.id))
                        .contains(where: Self.containsImage)
                }
                if !discovered.messages.isEmpty, shouldReplaceMessages || needsImageUpgrade {
                    record.messageCount = discovered.messages.count
                    let messages = try Self.persistableMessages(discovered.messages, store: store)
                    try store.replaceMessages(messages, for: record.id)
                }
                try store.saveSession(record)
                if let existingIndex {
                    sessions[existingIndex] = record
                } else {
                    sessions.append(record)
                    sessionIndexes[key] = sessions.endIndex - 1
                }
            }
        }
        try store.saveProjects(projects)
        sessions.sort { $0.updatedAt > $1.updatedAt }
        if selectedProjectID == nil {
            selectedProjectID = projects.first?.id
        }
        if let selectedSessionID {
            loadTranscript(for: selectedSessionID)
        }
    }

    private static func containsImage(_ message: Message) -> Bool {
        message.content.contains { if case .image = $0 { true } else { false } }
    }

    private struct DiscoverySessionKey: Hashable, Codable {
        let backendID: BackendID?
        let providerID: ProviderID
        let resumeToken: String?

        init(backendID: BackendID?, providerID: ProviderID, resumeToken: String?) {
            self.backendID = backendID
            self.providerID = providerID
            self.resumeToken = resumeToken
        }

        init(session: SessionRecord) {
            self.init(
                backendID: session.backendID,
                providerID: session.providerID,
                resumeToken: session.providerResumeToken
            )
        }
    }

    private func project(for rootPath: String?, backendID: BackendID) -> Project {
        if let existing = projects.first(where: {
            $0.rootPath == rootPath && self.backendID(for: $0) == backendID
        }) {
            return existing
        }
        let name = rootPath.map {
            let component = URL(fileURLWithPath: $0).lastPathComponent
            return component.isEmpty ? $0 : component
        } ?? "Conversations"
        let project = Project(
            name: name,
            rootPath: rootPath,
            metadata: ["backendID": backendID.rawValue, "discovered": "true"]
        )
        projects.append(project)
        return project
    }

    private func executionBackend(for record: SessionRecord) -> any ExecutionBackend {
        let backendID = record.backendID ?? DiscoveredMachine.local.id
        guard backendID.rawValue.hasPrefix("ssh:") else {
            return LocalProcessBackend()
        }
        let alias = String(backendID.rawValue.dropFirst("ssh:".count))
        return SSHBackend(id: backendID, displayName: alias, host: alias)
    }

    private func resetLiveState(for sessionID: SessionID? = nil) {
        liveText = ""
        liveThinking = ""
        liveTools = []
        liveSessionID = sessionID
    }

    private func requestPermission(
        _ request: PermissionRequest, sessionTitle: String? = nil
    ) async -> PermissionResponse {
        if let pendingPermissionRequest {
            permissionContinuation?.resume(
                returning: PermissionResponse(
                    requestID: pendingPermissionRequest.id,
                    decision: .deny,
                    reason: "A newer permission request replaced this request."
                )
            )
        }
        return await withCheckedContinuation { continuation in
            pendingPermissionRequest = request
            pendingPermissionSessionTitle = sessionTitle
            permissionContinuation = continuation
        }
    }

    private func loadTranscript(
        for sessionID: SessionID,
        includeProviderHistory: Bool = true
    ) {
        let loadToken = UUID()
        transcriptLoadToken = loadToken
        transcriptTask?.cancel()
        transcriptCursors[sessionID] = nil
        transcriptCacheCursors[sessionID] = nil
        let store: JSONDiskStore
        do {
            store = try requireStore()
        } catch {
            errorMessage = error.localizedDescription
            isLoadingTranscript = false
            return
        }
        isLoadingTranscript = messages.isEmpty
        let transcriptRecord: SessionRecord?
        if includeProviderHistory {
            transcriptRecord = sessions.first {
                $0.id == sessionID
                    && $0.providerResumeToken != nil
                    && ($0.backendID == DiscoveredMachine.local.id
                        || $0.backendID?.rawValue.hasPrefix("ssh:") == true)
            }
        } else {
            transcriptRecord = nil
        }
        transcriptTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    let page = try store.loadMessagesPage(for: sessionID)
                    return TranscriptLoadResult(
                        messages: page.messages,
                        olderCursor: page.olderCursor,
                        errorMessage: nil
                    )
                } catch {
                    return TranscriptLoadResult(
                        messages: [],
                        olderCursor: nil,
                        errorMessage: error.localizedDescription
                    )
                }
            }.value
            guard let self,
                  !Task.isCancelled,
                  isCurrentTranscriptLoad(loadToken, for: sessionID) else { return }
            messages = Self.mergeTranscriptMessages(result.messages, messages)
            errorMessage = result.errorMessage
            transcriptCacheCursors[sessionID] = result.olderCursor
            transcriptCursors[sessionID] = result.olderCursor.map(TranscriptCursor.cache)
            isLoadingTranscript = false
            if let transcriptRecord {
                do {
                    if let page = try await SessionTranscriptDiscovery.transcriptPage(for: transcriptRecord) {
                        guard !Task.isCancelled,
                              isCurrentTranscriptLoad(loadToken, for: sessionID) else { return }
                        let imported = page.session
                        let mergedMessages = Self.mergeTranscriptMessages(
                            imported.messages, messages
                        )
                        let visibleMessages = try await Self.persistableMessagesInBackground(
                            mergedMessages, store: store
                        )
                        guard !Task.isCancelled,
                              isCurrentTranscriptLoad(loadToken, for: sessionID) else { return }
                        messages = Self.mergeTranscriptMessages(visibleMessages, messages)
                        transcriptCursors[sessionID] = page.olderCursor.map(TranscriptCursor.provider)
                            ?? transcriptCacheCursors[sessionID].map(TranscriptCursor.cache)
                        var updated = transcriptRecord
                        updated.updatedAt = max(updated.updatedAt, imported.updatedAt)
                        save(updated)
                    }
                } catch {
                    guard !Task.isCancelled,
                          isCurrentTranscriptLoad(loadToken, for: sessionID) else { return }
                    errorMessage = "Session history could not be fully loaded: \(error.localizedDescription)"
                }
            }
            guard !Task.isCancelled,
                  isCurrentTranscriptLoad(loadToken, for: sessionID) else { return }
            transcriptTask = nil
        }
    }

    private func isCurrentTranscriptLoad(_ token: UUID, for sessionID: SessionID) -> Bool {
        selectedSessionID == sessionID && transcriptLoadToken == token
    }

    func loadOlderTranscript() async {
        guard let sessionID = selectedSessionID,
              loadingOlderTranscriptSessionID != sessionID,
              let cursor = transcriptCursors[sessionID],
              let store else { return }
        let loadToken = transcriptLoadToken
        loadingOlderTranscriptSessionID = sessionID
        defer {
            if loadingOlderTranscriptSessionID == sessionID {
                loadingOlderTranscriptSessionID = nil
            }
        }

        do {
            switch cursor {
            case .provider(let sourceCursor):
                guard let record = sessions.first(where: { $0.id == sessionID }) else {
                    transcriptCursors[sessionID] = transcriptCacheCursors[sessionID]
                        .map(TranscriptCursor.cache)
                    return
                }
                let page = try await SessionTranscriptDiscovery.transcriptPage(
                    for: record, before: sourceCursor
                )
                guard isCurrentTranscriptLoad(loadToken, for: sessionID) else { return }
                guard let page else {
                    transcriptCursors[sessionID] = transcriptCacheCursors[sessionID]
                        .map(TranscriptCursor.cache)
                    return
                }
                let mergedMessages = Self.mergeTranscriptMessages(page.session.messages, messages)
                let visibleMessages = try await Self.persistableMessagesInBackground(
                    mergedMessages, store: store
                )
                guard isCurrentTranscriptLoad(loadToken, for: sessionID) else { return }
                messages = Self.mergeTranscriptMessages(visibleMessages, messages)
                transcriptCursors[sessionID] = page.olderCursor.map(TranscriptCursor.provider)
                    ?? transcriptCacheCursors[sessionID].map(TranscriptCursor.cache)

            case .cache(let cacheCursor):
                let page = try await Task.detached(priority: .userInitiated) {
                    try store.loadMessagesPage(for: sessionID, before: cacheCursor)
                }.value
                guard isCurrentTranscriptLoad(loadToken, for: sessionID) else { return }
                messages = Self.mergeTranscriptMessages(page.messages, messages)
                transcriptCacheCursors[sessionID] = page.olderCursor
                if let currentCursor = transcriptCursors[sessionID],
                   case .provider = currentCursor {
                    return
                }
                transcriptCursors[sessionID] = page.olderCursor.map(TranscriptCursor.cache)
            }
        } catch {
            if isCurrentTranscriptLoad(loadToken, for: sessionID) {
                errorMessage = "Could not load older session messages: \(error.localizedDescription)"
            }
        }
    }

    nonisolated private static func mergeTranscriptMessages(
        _ older: [Message],
        _ newer: [Message]
    ) -> [Message] {
        var seen = Set<TranscriptMessageKey>()
        return (older + newer)
            .filter {
                seen.insert(TranscriptMessageKey(
                    origin: $0.origin.rawValue,
                    createdAt: $0.createdAt,
                    content: $0.content
                )).inserted
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    nonisolated private static func persistableMessages(
        _ messages: [Message],
        store: JSONDiskStore
    ) throws -> [Message] {
        try messages.map { message in
            var stored = message
            stored.content = try message.content.map { block in
                guard case .image(var attachment) = block,
                      case .inline(let data, let mediaType) = attachment.payload else { return block }
                attachment.payload = .blob(try store.storeBlob(
                    data, mediaType: mediaType, fileName: attachment.fileName
                ))
                return .image(attachment)
            }
            return stored
        }
    }

    nonisolated private static func persistableMessagesInBackground(
        _ messages: [Message],
        store: JSONDiskStore
    ) async throws -> [Message] {
        try await Task.detached(priority: .userInitiated) {
            try persistableMessages(messages, store: store)
        }.value
    }

    func loadUsageSummary(range: SessionUsageRange) async throws -> SessionUsageSummary {
        let store = try requireStore()
        let snapshot = sessions
        return try await Task.detached(priority: .utility) {
            let records = try snapshot.map { session in
                (session: session, messages: try store.loadMessages(for: session.id))
            }
            return SessionUsageSummary.summarize(records, range: range)
        }.value
    }

    private func requireStore() throws -> JSONDiskStore {
        guard let store else {
            throw SkynetError.persistenceFailure(
                underlying: "The application data directory is unavailable."
            )
        }
        return store
    }
}

private struct AppPermissionResponder: PermissionResponder {
    let handler: @Sendable (PermissionRequest) async -> PermissionResponse

    func decide(_ request: PermissionRequest) async -> PermissionResponse {
        await handler(request)
    }
}
