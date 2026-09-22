import AppKit
import SkynetCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isImporterPresented = false

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
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search sessions", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
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
            }
            .padding(12)

            List(selection: $model.selectedSessionID) {
                Section {
                    DisclosureGroup(isExpanded: .constant(true)) {
                        ForEach(model.filteredProjects) { project in
                            DisclosureGroup {
                                ForEach(model.sessions(for: project)) { session in
                                    SessionSidebarRow(session: session)
                                        .tag(session.id)
                                        .onTapGesture { model.select(session: session) }
                                }
                            } label: {
                                Label(project.name, systemImage: "folder")
                                    .font(.headline)
                                    .onTapGesture { model.select(project: project) }
                            }
                        }
                    } label: {
                        HStack {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text("This Mac").fontWeight(.semibold)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct SessionSidebarRow: View {
    let session: SessionRecord

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.providerID == .codex ? "sparkles" : "terminal")
                .foregroundStyle(session.status == .running ? .orange : .secondary)
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
