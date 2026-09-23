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
    var messages: [Message] = []
    var liveText = ""
    var liveThinking = ""
    var liveTools: [LiveTool] = []
    var searchText = ""
    var isRunning = false
    var workingSince: Date?
    var errorMessage: String?
    var pendingAttachments: [ImageAttachment] = []
    var machines: [DiscoveredMachine] = [.local]
    var disabledMachineIDs: Set<BackendID>
    var machineErrors: [BackendID: String] = [:]
    var isDiscovering = false
    var isLoadingTranscript = false
    private(set) var storageDirectoryURL: URL?

    private let store: JSONDiskStore?
    private var activeSession: AgentSession?
    private var streamTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?

    private static let disabledMachinesKey = "disabledMachineIDs"

    init() {
        disabledMachineIDs = Set(
            (UserDefaults.standard.stringArray(forKey: Self.disabledMachinesKey) ?? [])
                .map { BackendID($0) }
        )
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
        guard !query.isEmpty else { return projects }
        return projects.filter { project in
            projectMatchesSearch(project, query: query)
                || sessions.contains {
                    $0.projectID == project.id && sessionMatchesSearch($0, query: query)
                }
        }
    }

    func sessions(for project: Project) -> [SessionRecord] {
        sessions.filter { $0.projectID == project.id }
    }

    func filteredSessions(for project: Project) -> [SessionRecord] {
        let query = normalizedSearchText
        let projectSessions = sessions(for: project)
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
        if let first = sessions(for: project).first {
            select(session: first)
        } else {
            selectedSessionID = nil
            messages = []
        }
    }

    func select(session: SessionRecord) {
        selectedProjectID = session.projectID
        selectedSessionID = session.id
        resetLiveState()
        loadTranscript(for: session.id)
    }

    func clearSessionSelection() {
        selectedSessionID = nil
        transcriptTask?.cancel()
        transcriptTask = nil
        messages = []
        isLoadingTranscript = false
        resetLiveState()
    }

    func deleteSessions(_ ids: Set<SessionID>) {
        guard !ids.isEmpty else { return }
        do {
            let store = try requireStore()
            for id in ids {
                try store.deleteSession(id: id)
            }
            sessions.removeAll { ids.contains($0.id) }
            if let selectedSessionID, ids.contains(selectedSessionID) {
                clearSessionSelection()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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
        let model = provider.resolvedModelCatalog.resolvedDefaultModel
        let record = SessionRecord(
            projectID: project.id,
            providerID: provider.id,
            modelID: model?.id,
            effort: model?.defaultEffort,
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
        guard !trimmed.isEmpty else { return }
        session.title = trimmed
        session.updatedAt = Date()
        save(session)
    }

    func updateModel(_ modelID: ModelID?) {
        guard var session = selectedSession else { return }
        session.modelID = modelID
        if let provider = selectedProvider,
           let descriptor = modelID.flatMap({ provider.resolvedModelCatalog.model(with: $0) }) {
            session.effort = descriptor.defaultEffort
        }
        save(session)
    }

    func updateEffort(_ effort: ReasoningEffort?) {
        guard var session = selectedSession else { return }
        session.effort = effort
        save(session)
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
            pendingAttachments.append(
                ImageAttachment(data: data, mediaType: mediaType, fileName: url.lastPathComponent)
            )
        } catch {
            errorMessage = error.localizedDescription
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
                        permissions: .askEverything,
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
                let project = project(
                    for: discovered.workingDirectory,
                    backendID: snapshot.machine.id
                )
                let key = DiscoverySessionKey(
                    backendID: snapshot.machine.id,
                    providerID: discovered.providerID,
                    resumeToken: discovered.providerSessionID
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
                if record.title == nil { record.title = discovered.title }
                let shouldReplaceMessages = existingIndex == nil
                    || record.messageCount != discovered.messages.count
                    || previousUpdatedAt < discovered.updatedAt
                if !discovered.messages.isEmpty, shouldReplaceMessages {
                    record.messageCount = discovered.messages.count
                    try store.replaceMessages(discovered.messages, for: record.id)
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

    private struct DiscoverySessionKey: Hashable {
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

    private func requireStore() throws -> JSONDiskStore {
        guard let store else {
            throw SkynetError.persistenceFailure(
                underlying: "The application data directory is unavailable."
            )
        }
        return store
    }
}
