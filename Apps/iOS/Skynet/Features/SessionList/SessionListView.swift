import SwiftUI

/// Sessions of one project, with search, creation, rename, and delete.
/// Presented as the compact stack's second level and as the split view's
/// content column.
struct SessionListView: View {
    @State private var model: SessionListViewModel
    @State private var renamingSession: AgentSession?
    @State private var deletingSession: AgentSession?

    private let environment: AppEnvironment

    init(project: Project, environment: AppEnvironment) {
        self.environment = environment
        _model = State(
            initialValue: SessionListViewModel(
                project: project,
                relay: environment.relay,
                router: environment.router,
                sessionIndex: environment.sessionIndex
            )
        )
    }

    var body: some View {
        Group {
            if model.sessions.isEmpty && !model.isLoading {
                emptyState
            } else {
                sessionList
            }
        }
        .navigationTitle(model.project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.createSession() }
                } label: {
                    if model.isCreatingSession {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("New Session", systemImage: "square.and.pencil")
                    }
                }
                .disabled(model.isCreatingSession)
                .accessibilityIdentifier(A11yID.SessionList.newSessionButton)
            }
        }
        .overlay {
            if let loadError = model.loadError {
                BannerView(
                    loadError,
                    style: .warning,
                    actionTitle: "Retry",
                    action: { Task { await model.load() } }
                )
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .sheet(item: $renamingSession) { session in
            SessionRenameSheet(session: session) { newTitle in
                Task { await model.rename(session, to: newTitle) }
            }
        }
        .confirmationDialog(
            "Delete “\(deletingSession?.title ?? "")”?",
            isPresented: Binding(
                get: { deletingSession != nil },
                set: { if !$0 { deletingSession = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Session", role: .destructive) {
                if let session = deletingSession {
                    Task { await model.delete(session) }
                }
                deletingSession = nil
            }
            Button("Cancel", role: .cancel) { deletingSession = nil }
        } message: {
            Text("The transcript stays on your Mac's trash until emptied there.")
        }
        .task { await model.load() }
    }

    // MARK: - List

    private var sessionList: some View {
        List {
            if model.hasEmptySearchResults {
                Text("No sessions match “\(model.searchQuery)”")
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(model.filteredSessions) { session in
                    SessionRowView(session: session)
                        .contentShape(Rectangle())
                        .onTapGesture { environment.router.open(session: session) }
                        .contextMenu {
                            Button {
                                renamingSession = session
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .accessibilityIdentifier(A11yID.SessionList.renameAction(session.id))

                            Button(role: .destructive) {
                                deletingSession = session
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deletingSession = session
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                renamingSession = session
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(
                            EdgeInsets(
                                top: Theme.Spacing.xs,
                                leading: Theme.Spacing.md,
                                bottom: Theme.Spacing.xs,
                                trailing: Theme.Spacing.md
                            )
                        )
                        .accessibilityIdentifier(A11yID.SessionList.row(session.id))
                }
            }
        }
        .listStyle(.plain)
        .searchable(
            text: $model.searchQuery,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search sessions"
        )
        .accessibilityIdentifier(A11yID.SessionList.root)
        .refreshable { await model.load() }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "bubble.left.and.bubble.right",
            title: "No sessions yet",
            message: "Start a session to drive the agent on this project from your device.",
            actionTitle: "New Session",
            action: { Task { await model.createSession() } },
            actionAccessibilityID: A11yID.SessionList.emptyNewSessionButton
        )
        .overlay {
            if model.isLoading {
                ProgressView()
                    .controlSize(.large)
            }
        }
    }
}

/// One session row: state badge, title, latest preview, activity time,
/// unread marker.
struct SessionRowView: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.sm) {
                if session.state != .idle {
                    StatusDotView(
                        color: Theme.color(for: session.state),
                        isPulsing: session.state == .running
                    )
                }
                Text(session.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if session.unreadCount > 0 {
                    BadgeView("\(session.unreadCount)", tint: Theme.accent)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(SkynetFormatters.previewLine(for: session.lastPreview))
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Spacing.md)
                Text(SkynetFormatters.relativeTime(session.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(session.title), \(session.state.displayName), \(session.unreadCount) unread"
        )
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Previews

#Preview("Session list") {
    let environment = AppEnvironment.preview()
    return NavigationStack {
        SessionListView(project: PreviewData.project, environment: environment)
    }
    .environment(environment)
    .environment(environment.router)
}
