import AppKit
import SkynetCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isImporterPresented = false
    @State private var expansion = SidebarExpansionState()
    @State private var selectedSessionIDs: Set<SessionID> = []
    @State private var pendingDeletion: Set<SessionID> = []
    @State private var pendingProjectRemoval: Project?
    @State private var projectToRename: Project?
    @State private var projectNameDraft = ""
    @State private var machineFilterID: BackendID?
    @AppStorage("sidebarGroupingMode") private var groupingMode = "project"
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
        } detail: {
            if model.selectedSession != nil {
                SessionDetailView(model: model)
            } else {
                ContentUnavailableView(
                    "Start a session",
                    systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("Choose a project, then create a Codex or Claude Code session.")
                )
            }
        }
        .alert("Skynet", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.addProject(url: url)
            }
        }
        .onAppear {
            expansion.initialize(machines: model.machines, projects: model.projects)
            if let id = model.selectedSessionID { selectedSessionIDs = [id] }
        }
        .onChange(of: model.machines.map(\.id)) { _, _ in synchronizeExpansion() }
        .onChange(of: model.visibleMachines.map(\.id)) { _, ids in
            if let machineFilterID, !ids.contains(machineFilterID) { self.machineFilterID = nil }
        }
        .onChange(of: model.projects.map(\.id)) { _, _ in synchronizeExpansion() }
        .onChange(of: model.selectedSessionID) { _, id in
            if let id, !selectedSessionIDs.contains(id) {
                selectedSessionIDs = [id]
            } else if id == nil {
                selectedSessionIDs.removeAll()
            }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: deletionConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deletePendingSessions() }
            Button("Cancel", role: .cancel) { pendingDeletion.removeAll() }
        } message: {
            Text("Deletes the original Codex or Claude conversations and their cached transcripts from Skynet. Project files are not deleted.")
        }
        .confirmationDialog(
            "Remove \(pendingProjectRemoval?.name ?? "project")?",
            isPresented: Binding(
                get: { pendingProjectRemoval != nil },
                set: { if !$0 { pendingProjectRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Project", role: .destructive) {
                guard let project = pendingProjectRemoval else { return }
                selectedSessionIDs.subtract(model.sessions(for: project).map(\.id))
                model.removeProject(project)
                pendingProjectRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingProjectRemoval = nil }
        } message: {
            Text("Removes this project and its sessions from Skynet. Project files and original Codex or Claude conversations are not deleted.")
        }
        .alert("Rename Project", isPresented: Binding(
            get: { projectToRename != nil },
            set: { if !$0 { projectToRename = nil } }
        )) {
            TextField("Project name", text: $projectNameDraft)
            Button("Save") {
                if let projectToRename { model.renameProject(projectToRename, to: projectNameDraft) }
                projectToRename = nil
            }
            Button("Cancel", role: .cancel) { projectToRename = nil }
        }
    }

    private var sidebar: some View {
        let projectsByMachine = Dictionary(grouping: model.filteredProjects) {
            model.backendID(for: $0)
        }
        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Search sessions", text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                    Menu {
                        Button("All Machines") { machineFilterID = nil }
                        Divider()
                        ForEach(model.visibleMachines) { machine in
                            Button(machine.name) { machineFilterID = machine.id }
                        }
                    } label: {
                        SidebarActionIcon(systemName: machineFilterID == nil
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill")
                            .foregroundStyle(machineFilterID == nil ? .secondary : Color.accentColor)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("Filter by machine")
                    Button {
                        groupingMode = groupingMode == "project" ? "recent" : "project"
                    } label: {
                        Image(systemName: groupingMode == "recent" ? "bell.fill" : "bell")
                            .foregroundStyle(groupingMode == "recent" ? Color.accentColor : .secondary)
                            .frame(width: 28, height: 28)
                            .background(groupingMode == "recent" ? Color.accentColor.opacity(0.12) : .clear,
                                        in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(groupingMode == "recent" ? "Show projects" : "Group by recent activity")
                    .accessibilityLabel("Recent activity")
                    .accessibilityValue(groupingMode == "recent" ? "On" : "Off")
                }
                HStack(spacing: 4) {
                    Button(action: model.refreshDiscovery) {
                        if model.isDiscovering {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 28, height: 28)
                        } else {
                            SidebarActionIcon(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isDiscovering)
                    .help("Refresh machines and sessions")
                    Menu {
                        Button("Expand All", systemImage: "rectangle.expand.vertical") {
                            expansion.expandAll(machines: model.machines, projects: model.projects)
                        }
                        Button("Collapse All", systemImage: "rectangle.compress.vertical") {
                            expansion.collapseAll()
                        }
                    } label: {
                        SidebarActionIcon(systemName: "chevron.down.2")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("Expand or collapse all")

                    Spacer(minLength: 8)

                    Menu {
                        ForEach(model.providers, id: \.id) { provider in
                            Button(provider.displayName) { model.createSession(provider: provider) }
                        }
                    } label: {
                        SidebarActionIcon(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("New session")
                    Button { isImporterPresented = true } label: {
                        SidebarActionIcon(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .help("New project")
                    Button { openSettings() } label: {
                        SidebarActionIcon(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(height: 28)
            }
            .padding(12)

            List(selection: $selectedSessionIDs) {
                if groupingMode == "recent" {
                    if !globalPinnedSessions.isEmpty {
                        Section("Pinned") {
                            ForEach(globalPinnedSessions) { session in
                                sessionRow(session, context: recentSessionContext(session))
                            }
                        }
                    }
                    ForEach(recentSessionGroups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.sessions) { session in
                                sessionRow(session, context: recentSessionContext(session))
                            }
                        }
                    }
                } else {
                    ForEach(sidebarMachines) { machine in
                        SidebarDisclosureRow(
                            isExpanded: expansion.contains(machine.id),
                            action: { expansion.toggle(machine.id) }
                        ) {
                            Circle()
                                .fill(model.machineErrors[machine.id] == nil ? .green : .secondary)
                                .frame(width: 8, height: 8)
                            Image(systemName: machine.sshAlias == nil ? "desktopcomputer" : "server.rack")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(machine.name).fontWeight(.semibold)
                        }
                        .help(model.machineErrors[machine.id] ?? machine.name)

                        if expansion.contains(machine.id) {
                            ForEach(projectsByMachine[machine.id, default: []]) { project in
                                SidebarDisclosureRow(
                                    isExpanded: expansion.contains(project.id),
                                    action: {
                                        model.select(project: project)
                                        expansion.toggle(project.id)
                                    }
                                ) {
                                    Image(systemName: "folder")
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text(project.name)
                                                .font(.headline)
                                                .lineLimit(1)
                                            if project.metadata["pinned"] == "true" {
                                                Image(systemName: "pin.fill")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        if let path = project.rootPath {
                                            Text(path)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                                .help(path)
                                        }
                                    }
                                }
                                .padding(.leading, 16)
                                .contextMenu {
                                    projectLaunchActions(project)
                                    Divider()
                                    Button(project.metadata["pinned"] == "true" ? "Unpin" : "Pin",
                                           systemImage: "pin") {
                                        model.setProjectPinned(project, pinned: project.metadata["pinned"] != "true")
                                    }
                                    Button("Rename", systemImage: "pencil") {
                                        projectNameDraft = project.name
                                        projectToRename = project
                                    }
                                    Divider()
                                    if projectHasActiveChats(project) {
                                        Button("Archive chats", systemImage: "archivebox") {
                                            Task { await model.setProjectChatsArchived(project, archived: true) }
                                        }
                                        .disabled(!canNativelyArchive(model.sessions(for: project).filter { $0.isArchived != true })
                                            || model.isRunning && model.selectedProjectID == project.id)
                                        .help("Native archive requires Codex sessions with provider thread IDs.")
                                    }
                                    if projectHasArchivedChats(project) {
                                        Button("Restore archived chats", systemImage: "tray.and.arrow.up") {
                                            Task { await model.setProjectChatsArchived(project, archived: false) }
                                        }
                                    }
                                    Divider()
                                    if !model.sessions(for: project).isEmpty {
                                        Button("Delete all sessions in project", systemImage: "trash", role: .destructive) {
                                            requestDeletion(for: Set(model.sessions(for: project).map(\.id)))
                                        }
                                        .disabled(model.isRunning && model.selectedProjectID == project.id)
                                    }
                                    Button("Remove project", systemImage: "xmark", role: .destructive) {
                                        pendingProjectRemoval = project
                                    }
                                }

                                if expansion.contains(project.id) {
                                    ForEach(model.filteredSessions(for: project)) { session in
                                        sessionRow(session, indentation: 38)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selectedSessionIDs) { oldSelection, newSelection in
                updatePrimarySelection(from: oldSelection, to: newSelection)
            }
            .onDeleteCommand { requestDeletion(for: selectedSessionIDs) }
        }
    }

    private var deletionTitle: String {
        pendingDeletion.count == 1 ? "Delete Session?" : "Delete \(pendingDeletion.count) Sessions?"
    }

    private var deletionConfirmationPresented: Binding<Bool> {
        Binding(
            get: { !pendingDeletion.isEmpty },
            set: { if !$0 { pendingDeletion.removeAll() } }
        )
    }

    private func updatePrimarySelection(
        from oldSelection: Set<SessionID>,
        to newSelection: Set<SessionID>
    ) {
        guard !newSelection.isEmpty else {
            model.clearSessionSelection()
            return
        }
        let primaryID = newSelection.subtracting(oldSelection).first
            ?? model.selectedSessionID.flatMap { newSelection.contains($0) ? $0 : nil }
            ?? newSelection.first
        guard let primaryID,
              primaryID != model.selectedSessionID,
              let session = model.sessions.first(where: { $0.id == primaryID }) else { return }
        model.select(session: session)
    }

    private func requestDeletion(for id: SessionID) {
        requestDeletion(for: selectedSessionIDs.contains(id) ? selectedSessionIDs : [id])
    }

    private func requestDeletion(for ids: Set<SessionID>) {
        guard !ids.isEmpty else { return }
        pendingDeletion = ids
    }

    private func deletePendingSessions() {
        let targets = pendingDeletion
        pendingDeletion.removeAll()
        Task {
            let deleted = await model.deleteSessions(targets)
            selectedSessionIDs.subtract(deleted)
        }
    }

    private func synchronizeExpansion() {
        expansion.synchronize(machines: model.machines, projects: model.projects)
    }

    private func projectHasActiveChats(_ project: Project) -> Bool {
        model.sessions(for: project).contains { $0.isArchived != true }
    }

    private func projectHasArchivedChats(_ project: Project) -> Bool {
        model.sessions(for: project).contains { $0.isArchived == true }
    }

    private func canNativelyArchive(_ sessions: [SessionRecord]) -> Bool {
        !sessions.isEmpty && sessions.allSatisfy {
            $0.providerID == .codex && $0.providerResumeToken != nil
        }
    }

    private var recentSessionGroups: [SessionDateGroup] {
        let visibleMachines = Set(sidebarMachines.map(\.id))
        let visible = model.filteredProjects
            .filter { visibleMachines.contains(model.backendID(for: $0)) }
            .flatMap { model.filteredSessions(for: $0) }
        return SessionDateGrouping.groups(visible.filter { $0.pinMode != .global })
    }

    private var globalPinnedSessions: [SessionRecord] {
        let visibleMachines = Set(sidebarMachines.map(\.id))
        return model.filteredProjects
            .filter { visibleMachines.contains(model.backendID(for: $0)) }
            .flatMap { model.filteredSessions(for: $0) }
            .filter { $0.pinMode == .global }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var sidebarMachines: [DiscoveredMachine] {
        model.visibleMachines.filter { machineFilterID == nil || $0.id == machineFilterID }
    }

    private func recentSessionContext(_ session: SessionRecord) -> String? {
        guard let project = model.projects.first(where: { $0.id == session.projectID }) else {
            return nil
        }
        if session.backendID != DiscoveredMachine.local.id,
           let machine = model.machines.first(where: { $0.id == session.backendID })?.name {
            return "\(machine) · \(project.name)"
        }
        return project.name
    }

    private func sessionRow(
        _ session: SessionRecord,
        indentation: CGFloat = 0,
        context: String? = nil
    ) -> some View {
        SessionSidebarRow(session: session, context: context)
            .contentShape(Rectangle())
            .padding(.leading, indentation)
            .tag(session.id)
            .contextMenu {
                let targets = selectedSessionIDs.contains(session.id)
                    ? selectedSessionIDs : Set([session.id])
                if targets.count == 1,
                   let project = model.projects.first(where: { $0.id == session.projectID }) {
                    Menu("Pin", systemImage: "pin") {
                        Button("Pin in Project") {
                            model.setSessionPinMode(session, mode: .project)
                        }
                        Button("Pin Globally") {
                            model.setSessionPinMode(session, mode: .global)
                        }
                        if session.pinMode != nil {
                            Button("Unpin") { model.setSessionPinMode(session, mode: nil) }
                        }
                    }
                    Button("Mark as Unread", systemImage: "circle.fill") {
                        model.markSessionUnread(session)
                    }
                    Button("Copy Session ID", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.id.description, forType: .string)
                    }
                    Menu("Export", systemImage: "square.and.arrow.up") {
                        Button("JSON") { model.exportSession(session, format: .json) }
                        Button("Markdown") { model.exportSession(session, format: .markdown) }
                    }
                    if session.providerResumeToken != nil,
                       session.providerID == .codex || session.providerID == .claudeCode {
                        Button("Fork Current Session", systemImage: "square.on.square") {
                            Task { await model.forkSession(session) }
                        }
                        .disabled(model.isRunning && model.selectedSessionID == session.id)
                    }
                    Divider()
                    projectLaunchActions(project)
                    Button("Delete All Sessions in Project", systemImage: "trash", role: .destructive) {
                        requestDeletion(for: Set(model.sessions(for: project).map(\.id)))
                    }
                    .disabled(model.isRunning && model.selectedProjectID == project.id)
                    Divider()
                }
                Button(targets.count == 1 ? "Archive" : "Archive \(targets.count) Sessions",
                       systemImage: "archivebox") {
                    Task {
                        let archived = await model.setSessionsArchived(targets, archived: true)
                        selectedSessionIDs.subtract(archived)
                    }
                }
                .disabled(!canNativelyArchive(model.sessions.filter { targets.contains($0.id) })
                    || model.isRunning && model.selectedSessionID.map(targets.contains) == true)
                .help("Native archive requires Codex sessions with provider thread IDs.")
                Button(targets.count == 1 ? "Delete" : "Delete \(targets.count) Sessions",
                       systemImage: "trash", role: .destructive) {
                    requestDeletion(for: targets)
                }
                .disabled(model.isRunning && model.selectedSessionID.map(targets.contains) == true)
                if !selectedSessionIDs.isEmpty {
                    Divider()
                    Button("Clear Selection", systemImage: "xmark.circle") {
                        selectedSessionIDs.removeAll()
                    }
                }
            }
    }

    @ViewBuilder
    private func projectLaunchActions(_ project: Project) -> some View {
        Button("Open Project in VS Code", systemImage: "chevron.left.forwardslash.chevron.right") {
            model.openProjectInVSCode(project)
        }
        .disabled(project.rootPath == nil)
        Menu("New Session in Project", systemImage: "plus.bubble") {
            ForEach(model.providers, id: \.id) { provider in
                Button(provider.displayName) {
                    model.createSession(provider: provider, in: project)
                }
            }
        }
    }
}

private struct SidebarExpansionState {
    private var expandedMachines: Set<BackendID> = []
    private var expandedProjects: Set<ProjectID> = []
    private var knownMachines: Set<BackendID> = []
    private var knownProjects: Set<ProjectID> = []
    private var isInitialized = false

    func contains(_ id: BackendID) -> Bool { expandedMachines.contains(id) }
    func contains(_ id: ProjectID) -> Bool { expandedProjects.contains(id) }

    mutating func initialize(machines: [DiscoveredMachine], projects: [Project]) {
        guard !isInitialized else { return }
        isInitialized = true
        expandAll(machines: machines, projects: projects)
    }

    mutating func synchronize(machines: [DiscoveredMachine], projects: [Project]) {
        guard isInitialized else { return }
        let currentMachines = Set(machines.map(\.id))
        let currentProjects = Set(projects.map(\.id))
        expandedMachines.formUnion(currentMachines.subtracting(knownMachines))
        expandedProjects.formUnion(currentProjects.subtracting(knownProjects))
        knownMachines = currentMachines
        knownProjects = currentProjects
    }

    mutating func expandAll(machines: [DiscoveredMachine], projects: [Project]) {
        knownMachines = Set(machines.map(\.id))
        knownProjects = Set(projects.map(\.id))
        expandedMachines = knownMachines
        expandedProjects = knownProjects
    }

    mutating func collapseAll() {
        expandedMachines.removeAll()
        expandedProjects.removeAll()
    }

    mutating func toggle(_ id: BackendID) { expandedMachines.toggle(id) }
    mutating func toggle(_ id: ProjectID) { expandedProjects.toggle(id) }
}

private extension Set {
    mutating func toggle(_ element: Element) {
        if contains(element) {
            remove(element)
        } else {
            insert(element)
        }
    }
}

private struct SidebarActionIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }
}

private struct SidebarDisclosureRow<Label: View>: View {
    let isExpanded: Bool
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                label
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SessionSidebarRow: View {
    let session: SessionRecord
    var context: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            ProviderIcon(providerID: session.providerID, isRunning: session.status == .running)
            if session.markedUnreadAt != nil {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    .accessibilityLabel("Unread")
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.title ?? "New session")
                        .fontWeight(session.markedUnreadAt == nil ? .regular : .semibold)
                        .lineLimit(1)
                    if session.pinMode != nil {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(context ?? (session.providerID == .codex ? "Codex" : "Claude"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.updatedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

struct ProviderIcon: View {
    let providerID: ProviderID
    let isRunning: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            icon
            .resizable()
            .renderingMode(isBuiltIn ? .original : .template)
            .scaledToFit()
            .frame(width: 18, height: 18)
            .foregroundStyle(.secondary)

            if isRunning {
                Circle()
                    .fill(.orange)
                    .stroke(.background, lineWidth: 1)
                    .frame(width: 6, height: 6)
                    .offset(x: 1, y: 1)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private var isBuiltIn: Bool {
        providerID == .codex || providerID == .claudeCode
    }

    private var icon: Image {
        if providerID == .codex {
            return Image("ProviderCodex")
        }
        if providerID == .claudeCode {
            return Image("ProviderClaude")
        }
        return Image(systemName: "terminal")
    }
}
