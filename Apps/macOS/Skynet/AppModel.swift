import AppKit
import Foundation
import Observation
import SkynetCore

@MainActor
@Observable
final class AppModel {
    typealias QueuedPrompt = SessionComposerStorage.QueuedPrompt
    typealias ComposerDraft = SessionComposerStorage.ComposerDraft

    struct LiveTool: Identifiable {
        var id: ToolCallID
        var name: String
        var input: JSONValue
        var output: String?
        var isError = false
        var subagentStatus: SubagentStatusReport.Status?
    }

    var projects: [Project] = []
    var sessions: [SessionRecord] = []
    var providers: [AgentProviderDescriptor] = AgentProviderDescriptor.builtIns
    var selectedProjectID: ProjectID? {
        didSet { UserDefaults.standard.set(selectedProjectID?.description, forKey: AppPreferenceKey.selectedProject) }
    }
    var selectedSessionID: SessionID? {
        didSet {
            transcript.selectedSessionID = selectedSessionID
            UserDefaults.standard.set(selectedSessionID?.description, forKey: AppPreferenceKey.selectedSession)
        }
    }
    var messages: [Message] {
        get { transcript.messages }
        set { transcript.messages = newValue }
    }
    var transcriptGroups: [TranscriptGroup] { transcript.groups }
    var liveText = ""
    var liveThinking = ""
    var liveStatusText: String?
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
    var canStopSelectedSession: Bool {
        isSelectedSessionRunning
            || (selectedSessionID != nil && selectedSessionID == scheduledDispatchSessionID)
    }
    var pendingPermissionRequest: PermissionRequest? { permissionController.pendingPermissionRequest }
    var pendingPermissionSessionTitle: String? { permissionController.pendingPermissionSessionTitle }
    var machines: [DiscoveredMachine] = [.local] {
        didSet { connectivity.configure(machines: visibleMachines) }
    }
    var disabledMachineIDs: Set<BackendID> {
        didSet { connectivity.configure(machines: visibleMachines) }
    }
    let connectivity = NetworkConnectivityMonitor()
    @ObservationIgnored lazy var mobileRelay = MobileHostController(model: self)
    private var deletedDiscoveryKeys: Set<DiscoverySessionKey>
    var machineErrors: [BackendID: String] = [:]
    var isDiscovering = false
    var isLoadingTranscript: Bool { transcript.isLoadingTranscript }
    var isLoadingOlderTranscript: Bool { transcript.isLoadingOlderTranscript }
    private(set) var storageDirectoryURL: URL?

    private let store: JSONDiskStore?
    private let transcript: SessionTranscriptController
    private var activeSession: AgentSession?
    private var activeTurnSessionID: SessionID?
    private var liveSessionID: SessionID?
    private var streamTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private let permissionController = SessionPermissionController()
    private var pendingPermissionSessionID: SessionID? { permissionController.pendingPermissionSessionID }
    private var permissionRequestToken: UUID? { permissionController.permissionRequestToken }
    private var scheduleTimer: Task<Void, Never>?
    private var scheduledDispatch: Task<Void, Never>?
    private var scheduledDispatchSessionID: SessionID?
    private var scheduledSession: AgentSession?
    private var scheduledQueueSessionIDs: Set<SessionID> = []

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
            transcript = SessionTranscriptController(store: store)
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
            transcript = SessionTranscriptController(store: nil)
            errorMessage = "Unable to initialize Skynet storage: \(error.localizedDescription)"
        }
    }

    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedSession: SessionRecord? {
        sessions.first { $0.id == selectedSessionID }
    }

    var mobileActiveSessionID: SessionID? { activeTurnSessionID ?? scheduledDispatchSessionID }

    var mobilePermission: (request: PermissionRequest, token: UUID, owner: SessionID)? {
        guard let request = pendingPermissionRequest, let token = permissionRequestToken,
              let owner = pendingPermissionSessionID else { return nil }
        return (request, token, owner)
    }

    func mobileAnswerPermission(sessionID: SessionID, token: UUID, requestID: String,
                                decision: PermissionResponse.Decision) throws {
        guard let pending = mobilePermission, pending.owner == sessionID,
              pending.token == token, pending.request.id == requestID else {
            throw CocoaError(.userCancelled)
        }
        answerPermission(decision)
    }

    func mobileCancel(sessionID: SessionID) throws {
        guard let cancel = turnCancellationAction(for: sessionID) else { throw CocoaError(.userCancelled) }
        cancel()
    }

    func mobileSend(_ prompt: String, attachments: [ImageAttachment], record: SessionRecord) throws {
        guard !isRunning, scheduledDispatchSessionID != record.id, record.status != .running,
              store != nil, providers.contains(where: { $0.id == record.providerID }) else {
            throw NSError(domain: "SkynetMobile", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Another turn is running. Wait for it to finish before sending."])
        }
        send(prompt, mobileRecord: record, mobileAttachments: attachments)
        guard activeTurnSessionID == record.id else { throw CocoaError(.userCancelled) }
    }

    func mobileSave(_ record: SessionRecord) throws {
        try requireStore().saveSession(record)
        replace(record)
    }

    func mobileMessages(for sessionID: SessionID) async throws -> [Message] {
        let disk = try requireStore()
        return try await Task.detached(priority: .utility) {
            try disk.loadMessagesPage(for: sessionID, byteLimit: 512 * 1024).messages
        }.value
    }

    func mobileBackendID(for project: Project) -> BackendID { backendID(for: project) }

    var connectivityWarning: String? {
        if connectivity.networkAvailable == false {
            return "Network unavailable. Cached sessions remain available; reconnect to send messages."
        }
        guard let id = selectedSession?.backendID,
              let failure = connectivity.hosts[id]?.failure else { return nil }
        let name = machines.first { $0.id == id }?.name ?? id.rawValue
        return "\(name) is unavailable. Retrying automatically. \(failure)"
    }

    var canLoadOlderTranscript: Bool {
        transcript.canLoadOlderTranscript
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
        SessionLibraryQuery.projects(projects, sessions: sessions, query: normalizedSearchText)
    }

    func sessions(for project: Project) -> [SessionRecord] {
        sessions.filter { $0.projectID == project.id }
    }

    func filteredSessions(for project: Project) -> [SessionRecord] {
        SessionLibraryQuery.sessions(sessions, in: project, query: normalizedSearchText)
    }

    func filteredProjects(for machine: DiscoveredMachine) -> [Project] {
        filteredProjects.filter { backendID(for: $0) == machine.id }
    }

    func backendID(for project: Project) -> BackendID {
        BackendID(project.metadata["backendID"] ?? "local")
    }

    func refreshDiscovery() {
        // The selected transcript has its own paged loader; do not make it
        // wait for discovery of every local and remote session.
        if let selectedSessionID, !isLoadingOlderTranscript {
            loadTranscript(for: selectedSessionID, preservePagination: true)
        }
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
            machines = MacSessionDiscovery.cachedMachines(projects: projects, sessions: sessions)
            recoverInterruptedLocalSessions(in: &sessions, store: store)
            scheduledQueueSessionIDs = Set(sessions.compactMap { session in
                queueEntries(for: session.id).contains(where: {
                    $0.scheduledAt != nil && $0.dispatchStartedAt == nil
                }) ? session.id : nil
            })
            providers = try ProviderCatalog.effective(
                userConfigured: store.loadUserProviders()
            ).providers
            if selectedSessionID == nil,
               let rawID = UserDefaults.standard.string(forKey: AppPreferenceKey.selectedSession),
               let uuid = UUID(uuidString: rawID),
               let session = sessions.first(where: { $0.id == SessionID(uuid) && $0.isArchived != true }),
               projects.contains(where: { $0.id == session.projectID }) {
                selectedProjectID = session.projectID
                selectedSessionID = session.id
            }
            if selectedProjectID == nil,
               let rawID = UserDefaults.standard.string(forKey: AppPreferenceKey.selectedProject),
               let uuid = UUID(uuidString: rawID),
               projects.contains(where: { $0.id == ProjectID(uuid) }) {
                selectedProjectID = ProjectID(uuid)
            }
            if selectedProjectID == nil { selectedProjectID = projects.first?.id }
            if selectedSessionID == nil, let project = selectedProject {
                selectedSessionID = sessions(for: project).first?.id
            }
            if let selectedSessionID {
                loadQueue(for: selectedSessionID)
                loadTranscript(for: selectedSessionID)
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
                let cachedMessages = try await Task.detached(priority: .userInitiated) {
                    try store.loadMessages(for: session.id)
                }.value
                // Export the whole provider-backed transcript, not only the
                // cache or the currently visible page. Each read stays bounded.
                var cursor: Int64?
                var providerMessages: [Message] = []
                repeat {
                    try Task.checkCancellation()
                    guard let page = try await SessionTranscriptDiscovery.transcriptPage(
                        for: session, before: cursor
                    ) else { break }
                    providerMessages.append(contentsOf: page.session.messages)
                    if let next = page.olderCursor, let cursor, next >= cursor {
                        throw SkynetError.executionFailed(reason: "History export cursor did not advance.")
                    }
                    cursor = page.olderCursor
                } while cursor != nil
                let history = providerMessages
                let data = try await Task.detached(priority: .userInitiated) {
                    try SessionTranscriptExport.data(
                        session: session,
                        messages: TranscriptMessageMerger.merge(cachedMessages, history),
                        format: format,
                        loadBlob: { try store.loadBlob($0) }
                    )
                }.value
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
        transcript.clear()
        selectedSessionID = nil
        queuedPrompts = []
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
            if (isRunning && activeTurnSessionID == session.id)
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
                composerStorage.removeSessionFiles(for: id)
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

    var permissionDecisionAction: (PermissionResponse.Decision) -> Void {
        let token = permissionRequestToken
        return { [weak self] decision in
            // A sheet callback can outlive its request. Provider IDs/session
            // IDs may be reused; only its captured continuation may be answered.
            guard let self, let token, self.permissionRequestToken == token else { return }
            self.answerPermission(decision)
        }
    }

    func answerPermission(_ decision: PermissionResponse.Decision) {
        permissionController.answerPermission(decision)
    }

    func attachImage(url: URL) {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            pendingAttachments.append(try ComposerImageImport.load(url: url))
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

    var shouldQueueComposerSubmission: Bool {
        isRunning || (selectedSessionID != nil && scheduledDispatchSessionID == selectedSessionID)
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

    private var composerStorage: SessionComposerStorage {
        .init(rootURL: storageDirectoryURL, blobs: store)
    }

    private func storedAttachments(_ attachments: [ImageAttachment]) throws -> [ImageAttachment] {
        try composerStorage.storedAttachments(attachments)
    }

    func saveComposerDraft(_ text: String, attachments: [ImageAttachment], for sessionID: SessionID) {
        do {
            try composerStorage.saveDraft(text, attachments: attachments, for: sessionID)
        } catch {
            errorMessage = "Could not save composer draft: \(error.localizedDescription)"
        }
    }

    func loadComposerDraft(for sessionID: SessionID) -> ComposerDraft? {
        composerStorage.loadDraft(for: sessionID)
    }

    private func loadQueue(for sessionID: SessionID) {
        queuedPrompts = queueEntries(for: sessionID)
    }

    private func queueEntries(for sessionID: SessionID) -> [QueuedPrompt] {
        composerStorage.queueEntries(for: sessionID)
    }

    private func persistQueue(_ entries: [QueuedPrompt], for sessionID: SessionID) throws {
        try composerStorage.persistQueue(entries, for: sessionID)
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
        // send can reject synchronously without consuming the queue's images.
        // Its temporary input must never become part of the independent draft.
        defer { pendingAttachments = composerAttachments }
        pendingAttachments = entry.attachments
        send(entry.text, queuedEntry: entry)
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
            var deliveredSuccessfully = false
            var dispatchMarked = false
            var agent: AgentSession?
            defer {
                scheduledDispatch = nil
                scheduledDispatchSessionID = nil
                scheduledSession = nil
                if deliveredSuccessfully, !Task.isCancelled { sendNextQueued(for: record.id) }
                deliverMatureScheduledMessage()
            }
            do {
                try Task.checkCancellation()
                var queue = queueEntries(for: record.id)
                guard let index = queue.firstIndex(where: { $0.id == entry.id }) else { return }
                queue[index].dispatchStartedAt = Date()
                try persistQueue(queue, for: record.id)
                dispatchMarked = true
                if selectedSessionID == record.id { queuedPrompts = queue }

                let executor = try SessionTurnExecutor(
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
                                request, sessionID: record.id,
                                sessionTitle: record.title ?? "Scheduled session"
                            )
                        },
                        store: store
                    )
                )
                agent = executor.session
                scheduledSession = executor.session
                let result = try await executor.runScheduled(entry.text)
                var updated = result.record
                if selectedSessionID != record.id { updated.markedUnreadAt = Date() }
                try store.saveSession(updated)
                replace(updated)
                if selectedSessionID == record.id { loadTranscript(for: record.id) }
                if let failure = result.failure { throw failure }
                guard result.completedSuccessfully else {
                    throw SkynetError.executionFailed(reason: "Scheduled turn did not complete successfully.")
                }
                removeQueuedPrompt(entry.id, for: record.id)
                deliveredSuccessfully = !queueEntries(for: record.id).contains { $0.id == entry.id }
            } catch {
                if !dispatchMarked {
                    // An unwritten marker leaves this same entry eligible and
                    // defer would retry immediately. Pause this registration
                    // until queue re-persistence or reload re-arms it, without
                    // starving other sessions.
                    scheduledQueueSessionIDs.remove(record.id)
                }
                errorMessage = "Scheduled message needs review: \(error.localizedDescription)"
            }
            // Keep ownership until provider termination is finished, just as
            // ordinary Stop does. A cancelled consumer alone is not an exit.
            if Task.isCancelled, let agent {
                await agent.cancelActiveTurn()
                let updated = await agent.record
                replace(updated)
                if selectedSessionID == record.id { loadTranscript(for: record.id) }
            }
        }
    }


    func send(_ prompt: String, queuedEntry: QueuedPrompt? = nil,
              mobileRecord: SessionRecord? = nil, mobileAttachments: [ImageAttachment]? = nil) {
        guard !isRunning, let store, let record = mobileRecord ?? selectedSession,
              let provider = providers.first(where: { $0.id == record.providerID }) else { return }
        guard scheduledDispatchSessionID != record.id else {
            errorMessage = "A scheduled message is already sending in this session."
            return
        }
        let attachments = mobileAttachments ?? pendingAttachments
        let referenceSessions = sessions
        if mobileAttachments == nil { pendingAttachments = [] }
        resetLiveState(for: record.id)
        isRunning = true
        activeTurnSessionID = record.id
        workingSince = Date()
        errorMessage = nil

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            var completedTurn = false
            let activityStart = Date()
            defer {
                isRunning = false
                activeTurnSessionID = nil
                workingSince = nil
                activeSession = nil
                liveStatusText = nil
                streamTask = nil
                if Task.isCancelled { liveTools.removeAll() }
                mobileRelay.finishTurn(for: record.id)
                let steeredID = steeringQueuedPromptID
                steeringQueuedPromptID = nil
                if let steeredID,
                   let entry = queueEntries(for: record.id).first(where: { $0.id == steeredID }) {
                    sendQueuedPrompt(entry, for: record.id)
                } else if completedTurn, !Task.isCancelled {
                    sendNextQueued(for: record.id)
                }
            }
            do {
                try Task.checkCancellation()
                let executor = try SessionTurnExecutor(
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
                                return await self.requestPermission(request, sessionID: record.id)
                            }
                            : nil,
                        store: store
                    )
                )
                activeSession = executor.session
                completedTurn = await executor.runOrdinary(
                    prompt, attachments: attachments, referenceSessions: referenceSessions,
                    store: store, activityStart: activityStart,
                    callbacks: .init(
                        started: {
                            if let queuedEntry { self.removeQueuedPrompt(queuedEntry.id, for: record.id) }
                        },
                        receive: { self.apply($0, sessionID: record.id) },
                        updateRecord: { self.replace($0) },
                        failed: { error, started in
                            self.handleTurnFailure(error, didStartTurn: started,
                                                   record: record, attachments: attachments,
                                                   queuedEntry: queuedEntry, restoreDraft: mobileAttachments == nil)
                        }
                    )
                )
            } catch {
                // The executor consumes turn errors; only pre-turn setup can throw here.
                handleTurnFailure(error, didStartTurn: false,
                                  record: record, attachments: attachments, queuedEntry: queuedEntry,
                                  restoreDraft: mobileAttachments == nil)
            }
        }
    }

    private func handleTurnFailure(
        _ error: Error, didStartTurn: Bool, record: SessionRecord,
        attachments: [ImageAttachment], queuedEntry: QueuedPrompt?, restoreDraft: Bool = true
    ) {
        if !(error is CancellationError), steeringQueuedPromptID == nil {
            errorMessage = error.localizedDescription
        }
        if restoreDraft, !didStartTurn, queuedEntry == nil, selectedSessionID == record.id {
            pendingAttachments.insert(contentsOf: attachments, at: 0)
        }
    }

    func cancel() {
        turnCancellationAction(for: selectedSessionID)?()
    }

    var canStopPermissionTurn: Bool {
        permissionTurnStopAction != nil
    }

    var permissionTurnStopAction: (() -> Void)? {
        // Capture while building the dialog: native dismissal can clear the
        // pending request before the button's action runs.
        turnCancellationAction(for: pendingPermissionSessionID)
    }

    private func turnCancellationAction(for sessionID: SessionID?) -> (() -> Void)? {
        guard let sessionID else { return nil }
        let session: AgentSession?
        let task: Task<Void, Never>?
        if sessionID == scheduledDispatchSessionID {
            session = scheduledSession
            task = scheduledDispatch
        } else {
            guard sessionID == activeTurnSessionID else { return nil }
            session = activeSession
            task = streamTask
        }
        let permissionToken = permissionRequestToken
        return { [weak self] in
            if let self, self.pendingPermissionSessionID == sessionID,
               self.permissionRequestToken == permissionToken {
                self.answerPermission(.deny)
            }
            // Exact task/actor snapshots cannot target a later turn, even if
            // selection, request ID or the request owner changes meanwhile.
            task?.cancel()
            Task { await session?.cancelActiveTurn() }
        }
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
        mobileRelay.receive(event, for: sessionID)
        switch event {
        case .textDelta(let text): liveText += text
        case .thinkingDelta(let text): liveThinking += text
        case .statusUpdate(let text): liveStatusText = text
        case .messageCompleted(let message):
            guard selectedSessionID == sessionID else { return }
            if !messages.contains(where: { $0.id == message.id }) { messages.append(message) }
        case .toolCallStarted(let call):
            if !liveTools.contains(where: { $0.id == call.id }) {
                liveTools.append(LiveTool(id: call.id, name: call.name, input: call.input))
            }
        case .toolCallCompleted(let result):
            if let index = liveTools.firstIndex(where: { $0.id == result.toolCallID }) {
                liveTools[index].output = result.content
                liveTools[index].isError = result.isError
            }
        case .subagentStatusReported(let report):
            let id = ToolCallID("subagent:\(report.agentThreadID)")
            let index = liveTools.firstIndex(where: { $0.id == id })
            let path = report.agentPath
                ?? index.flatMap { liveTools[$0].input["agent_path"]?.stringValue }
                ?? report.agentThreadID
            let row = LiveTool(
                id: id, name: "Subagent",
                input: ["agent_thread_id": .string(report.agentThreadID),
                        "agent_path": .string(path)],
                output: report.status.isActive ? nil : report.message ?? "",
                isError: report.status.isError, subagentStatus: report.status
            )
            if let index {
                liveTools[index] = row
            } else {
                liveTools.append(row)
            }
        case .turnCompleted(let summary) where summary.stopReason == .cancelled:
            // Cancelled providers may exit without individual tool-completion
            // events. Their previous live rows are no longer current activity.
            liveTools.removeAll()
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

    private func mergeDiscovery(_ snapshots: [MachineSessionSnapshot]) throws {
        guard let store else { return }
        machines = snapshots.map(\.machine)
        machineErrors = Dictionary(
            uniqueKeysWithValues: snapshots.compactMap { snapshot in
                snapshot.error.map { (snapshot.machine.id, $0) }
            }
        )

        try SessionDiscoveryRegistry.merge(
            snapshots, projects: &projects, sessions: &sessions,
            deletedKeys: deletedDiscoveryKeys, selectedSessionID: selectedSessionID, store: store
        )
        if selectedProjectID == nil {
            selectedProjectID = projects.first?.id
        }
        if let selectedSessionID, !isLoadingOlderTranscript {
            loadTranscript(for: selectedSessionID, preservePagination: true)
        }
    }

    func executionBackend(for record: SessionRecord) -> any ExecutionBackend {
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
        liveStatusText = nil
        liveTools = []
        liveSessionID = sessionID
    }

    private func requestPermission(
        _ request: PermissionRequest, sessionID: SessionID, sessionTitle: String? = nil
    ) async -> PermissionResponse {
        await permissionController.request(request, sessionID: sessionID, sessionTitle: sessionTitle)
    }

    private var transcriptHooks: SessionTranscriptController.Hooks {
        .init(
            record: { [weak self] id in self?.sessions.first { $0.id == id } },
            save: { [weak self] in self?.save($0) },
            reportError: { [weak self] in self?.errorMessage = $0 }
        )
    }

    private func loadTranscript(
        for sessionID: SessionID,
        includeProviderHistory: Bool = true,
        preservePagination: Bool = false
    ) {
        let record = includeProviderHistory ? sessions.first {
            $0.id == sessionID
                && $0.providerResumeToken != nil
                && ($0.backendID == DiscoveredMachine.local.id
                    || $0.backendID?.rawValue.hasPrefix("ssh:") == true)
        } : nil
        transcript.load(for: sessionID, record: record,
                        preservePagination: preservePagination, hooks: transcriptHooks)
    }

    func loadOlderTranscript() async {
        await transcript.loadOlderTranscript(hooks: transcriptHooks)
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
