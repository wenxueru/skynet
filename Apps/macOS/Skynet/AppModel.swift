import AppKit
import Foundation
import Observation
import SkynetCore

@MainActor
@Observable
final class AppModel {
    struct LiveTool: Identifiable {
        var id: ToolCallID
        var name: String
        var input: JSONValue
        var output: String?
        var isError = false
    }

    private struct TranscriptLoadResult: Sendable {
        let messages: [Message]
        let errorMessage: String?
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
    var workingSince: Date?
    var errorMessage: String?
    var pendingAttachments: [ImageAttachment] = []
    var pendingPermissionRequest: PermissionRequest?
    var machines: [DiscoveredMachine] = [.local]
    var disabledMachineIDs: Set<BackendID>
    private var deletedDiscoveryKeys: Set<DiscoverySessionKey>
    var machineErrors: [BackendID: String] = [:]
    var isDiscovering = false
    var isLoadingTranscript = false
    private(set) var storageDirectoryURL: URL?

    private let store: JSONDiskStore?
    private var activeSession: AgentSession?
    private var streamTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    private var permissionContinuation: CheckedContinuation<PermissionResponse, Never>?

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
        let matching = query.isEmpty ? projects : projects.filter { project in
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
            providers = try ProviderCatalog.effective(
                userConfigured: store.loadUserProviders()
            ).providers
            if selectedProjectID == nil { selectedProjectID = projects.first?.id }
            if selectedSessionID == nil, let project = selectedProject {
                selectedSessionID = sessions(for: project).first?.id
            }
            if let selectedSessionID {
                messages = try store.loadMessages(for: selectedSessionID)
            }
        } catch {
            errorMessage = error.localizedDescription
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
            selectedSessionID = nil
            messages = []
        }
    }

    func select(session: SessionRecord) {
        selectedProjectID = session.projectID
        selectedSessionID = session.id
        if session.markedUnreadAt != nil {
            var updated = session
            updated.markedUnreadAt = nil
            save(updated)
        }
        resetLiveState()
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
        selectedSessionID = nil
        transcriptTask?.cancel()
        transcriptTask = nil
        messages = []
        isLoadingTranscript = false
        resetLiveState()
    }

    @discardableResult
    func deleteSessions(_ ids: Set<SessionID>) async -> Set<SessionID> {
        var deleted: Set<SessionID> = []
        var failures: [String] = []
        for session in sessions where ids.contains(session.id) {
            if isRunning && selectedSessionID == session.id {
                failures.append("Stop \(session.title ?? "the running session") before deleting it.")
                continue
            }
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
                deleted.insert(session.id)
            } catch {
                failures.append("\(session.title ?? "Session"): \(error.localizedDescription)")
            }
        }
        if !deleted.isEmpty && !removeCachedSessions(deleted) {
            failures.append("The original session was deleted, but its Skynet cache could not be removed.")
            deleted.removeAll()
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        return deleted
    }

    @discardableResult
    private func removeCachedSessions(_ ids: Set<SessionID>) -> Bool {
        guard !ids.isEmpty else { return true }
        if isRunning, let selectedSessionID, ids.contains(selectedSessionID) {
            errorMessage = "Stop the running session before deleting it."
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

    func send(_ prompt: String) {
        guard !isRunning, let store, let record = selectedSession,
              let provider = providers.first(where: { $0.id == record.providerID }) else { return }
        let attachments = pendingAttachments
        pendingAttachments = []
        resetLiveState()
        isRunning = true
        workingSince = Date()
        errorMessage = nil

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            var didStartTurn = false
            defer {
                isRunning = false
                workingSince = nil
                activeSession = nil
                streamTask = nil
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
                let stream = try await session.send(prompt, attachments: attachments)
                didStartTurn = true
                for try await event in stream {
                    apply(event)
                }
                let updated = await session.record
                replace(updated)
                messages = try store.loadMessages(for: updated.id)
            } catch {
                errorMessage = error.localizedDescription
                if !didStartTurn {
                    pendingAttachments.insert(contentsOf: attachments, at: 0)
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

    private func apply(_ event: AgentEvent) {
        switch event {
        case .textDelta(let text): liveText += text
        case .thinkingDelta(let text): liveThinking += text
        case .messageCompleted(let message):
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
                let shouldReplaceMessages = existingIndex == nil
                    || record.messageCount != discovered.messages.count
                    || previousUpdatedAt < discovered.updatedAt
                var needsImageUpgrade = false
                if !shouldReplaceMessages,
                   discovered.messages.contains(where: Self.containsImage) {
                    needsImageUpgrade = !(try store.loadMessages(for: record.id))
                        .contains(where: Self.containsImage)
                }
                if !discovered.messages.isEmpty, shouldReplaceMessages || needsImageUpgrade {
                    record.messageCount = discovered.messages.count
                    let messages = try discovered.messages.map { message in
                        var stored = message
                        stored.content = try message.content.map { block in
                            guard case .image(var attachment) = block,
                                  case .inline(let data, let mediaType) = attachment.payload else {
                                return block
                            }
                            attachment.payload = .blob(try store.storeBlob(
                                data, mediaType: mediaType, fileName: attachment.fileName
                            ))
                            return .image(attachment)
                        }
                        return stored
                    }
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

    private func resetLiveState() {
        liveText = ""
        liveThinking = ""
        liveTools = []
    }

    private func requestPermission(_ request: PermissionRequest) async -> PermissionResponse {
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
            permissionContinuation = continuation
        }
    }

    private func loadTranscript(for sessionID: SessionID) {
        transcriptTask?.cancel()
        let store: JSONDiskStore
        do {
            store = try requireStore()
        } catch {
            messages = []
            errorMessage = error.localizedDescription
            isLoadingTranscript = false
            return
        }
        isLoadingTranscript = true
        messages = []
        transcriptTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    return TranscriptLoadResult(
                        messages: try store.loadMessages(for: sessionID),
                        errorMessage: nil
                    )
                } catch {
                    return TranscriptLoadResult(
                        messages: [],
                        errorMessage: error.localizedDescription
                    )
                }
            }.value
            guard let self, !Task.isCancelled, selectedSessionID == sessionID else { return }
            messages = result.messages
            errorMessage = result.errorMessage
            isLoadingTranscript = false
            transcriptTask = nil
        }
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
