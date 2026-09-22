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

    private let store: JSONDiskStore?
    private var activeSession: AgentSession?
    private var streamTask: Task<Void, Never>?

    init() {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            store = try JSONDiskStore(rootURL: base.appendingPathComponent("Skynet", isDirectory: true))
            load()
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
        if let existing = projects.first(where: { $0.rootPath == standardized }) {
            select(project: existing)
            return
        }
        let project = Project(name: url.lastPathComponent, rootPath: standardized)
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
        do {
            let store = try requireStore()
            messages = try store.loadMessages(for: session.id)
        } catch {
            errorMessage = error.localizedDescription
        }
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
            backendID: BackendID("local"),
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
                        backend: LocalProcessBackend(),
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

    private func resetLiveState() {
        liveText = ""
        liveThinking = ""
        liveTools = []
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
