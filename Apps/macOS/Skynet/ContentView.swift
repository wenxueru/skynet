import AppKit
import SkynetCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isImporterPresented = false
    @State private var expansion = SidebarExpansionState()
    @State private var selectedSessionIDs: Set<SessionID> = []
    @State private var pendingDeletion: Set<SessionID> = []
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
            Text("This removes the selected sessions and their locally cached transcripts.")
        }
    }

    private var sidebar: some View {
        let projectsByMachine = Dictionary(grouping: model.filteredProjects) {
            model.backendID(for: $0)
        }
        return VStack(spacing: 0) {
            HStack {
                TextField("Search sessions", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                Button(action: model.refreshDiscovery) {
                    if model.isDiscovering {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
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
                    Image(systemName: "chevron.down.2")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Expand or collapse all")
                Menu {
                    ForEach(model.providers, id: \.id) { provider in
                        Button(provider.displayName) { model.createSession(provider: provider) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .help("New session")
                Button { isImporterPresented = true } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .help("New project")
                Button { openSettings() } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(12)

            List(selection: $selectedSessionIDs) {
                ForEach(model.visibleMachines) { machine in
                    SidebarDisclosureRow(
                        isExpanded: expansion.contains(machine.id),
                        action: { expansion.toggle(machine.id) }
                    ) {
                        Circle()
                            .fill(model.machineErrors[machine.id] == nil ? .green : .secondary)
                            .frame(width: 8, height: 8)
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
                                Text(project.name).font(.headline)
                            }
                            .padding(.leading, 16)

                            if expansion.contains(project.id) {
                                ForEach(model.filteredSessions(for: project)) { session in
                                    SessionSidebarRow(session: session)
                                        .contentShape(Rectangle())
                                        .padding(.leading, 38)
                                        .tag(session.id)
                                        .contextMenu {
                                            Button("Delete", systemImage: "trash", role: .destructive) {
                                                requestDeletion(for: session.id)
                                            }
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
        model.deleteSessions(pendingDeletion)
        selectedSessionIDs.subtract(pendingDeletion)
        pendingDeletion.removeAll()
    }

    private func synchronizeExpansion() {
        expansion.synchronize(machines: model.machines, projects: model.projects)
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

    var body: some View {
        HStack(spacing: 8) {
            ProviderIcon(providerID: session.providerID, isRunning: session.status == .running)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title ?? "New session").lineLimit(1)
                Text(session.providerID == .codex ? "Codex" : "Claude")
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

private struct ProviderIcon: View {
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
