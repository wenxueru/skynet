import SwiftUI

/// A single session screen: live transcript, in-transcript search, jump to
/// bottom, permission cards, the queued-prompts bar, and the composer.
/// Presented as the compact stack's leaf and the split view's detail column.
struct SessionView: View {
    @State private var model: SessionViewModel
    @State private var composerModel: ComposerViewModel
    @State private var isRenamePresented = false
    @State private var isSettingsPresented = false
    @State private var isQueueSheetPresented = false
    @State private var searchQuery = ""
    @State private var isSearchPresented = false

    private let environment: AppEnvironment

    init(session: AgentSession, environment: AppEnvironment) {
        self.environment = environment
        let sessionModel = SessionViewModel(
            session: session,
            relay: environment.relay,
            monitor: environment.monitor,
            notifications: environment.notifications,
            liveActivities: environment.liveActivities,
            activityState: environment.activityState
        )
        _model = State(initialValue: sessionModel)
        _composerModel = State(initialValue: ComposerViewModel(state: sessionModel))
    }

    private var search: TranscriptSearch? {
        isSearchPresented && !searchQuery.isEmpty
            ? TranscriptSearch(query: searchQuery)
            : nil
    }

    private var matchCount: Int {
        search?.matchCount(in: model.items) ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.errorBanner {
                BannerView(
                    error,
                    style: .error,
                    actionTitle: "Dismiss",
                    action: { model.dismissError() }
                )
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.xs)
            }
            ConnectionBannerView(monitor: environment.monitor)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.xs)

            if let search {
                searchSummary(search)
            }

            TranscriptView(
                items: model.items,
                search: search,
                onPermissionDecision: { record, decision in
                    Task { await model.resolve(record, decision: decision) }
                }
            )
            .overlay(alignment: .bottom) {
                if model.isCanceling {
                    ProgressView()
                        .padding(.bottom, Theme.Spacing.sm)
                }
            }

            QueuedPromptsBar(state: model, onOpenQueue: { isQueueSheetPresented = true })

            ComposerView(model: composerModel)
        }
        .navigationTitle(model.currentSession.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        isRenamePresented = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .accessibilityIdentifier(A11yID.Session.renameButton)

                    Button {
                        isSettingsPresented = true
                    } label: {
                        Label("Session Settings", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier(A11yID.Session.settingsButton)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier(A11yID.Session.menuButton)
                .accessibilityLabel("Session actions")
            }
            ToolbarItem(placement: .cancellationAction) {
                if model.currentTurnState.isBusy {
                    Button {
                        Task { await model.cancelTurn() }
                    } label: {
                        Label("Stop Turn", systemImage: "stop.fill")
                    }
                    .tint(Theme.danger)
                    .accessibilityIdentifier(A11yID.Session.cancelTurnButton)
                }
            }
        }
        .searchable(
            text: $searchQuery,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search transcript"
        )
        .sheet(isPresented: $isRenamePresented) {
            SessionRenameSheet(session: model.currentSession) { newTitle in
                Task { await model.rename(to: newTitle) }
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SessionSettingsSheet(
                session: model.currentSession,
                availableModels: model.availableModels
            ) { configuration in
                model.composerDidChangeConfiguration(configuration)
            }
        }
        .sheet(isPresented: $isQueueSheetPresented) {
            QueuedPromptsSheet(state: model) {
                isQueueSheetPresented = false
            }
        }
        .task {
            model.start()
        }
        .onAppear {
            model.setViewVisible(true)
        }
        .onDisappear {
            model.setViewVisible(false)
            model.stop()
        }
        .onChange(of: model.currentSession.title) { _, _ in
            environment.router.refreshSelected(session: model.currentSession)
        }
    }

    // MARK: - Search summary

    private func searchSummary(_ search: TranscriptSearch) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text("\(matchCount) \(matchCount == 1 ? "match" : "matches")")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.secondary)
                .accessibilityIdentifier(A11yID.Session.searchResultCount)
            Spacer()
            Button {
                searchQuery = ""
                isSearchPresented = false
            } label: {
                Label("Clear", systemImage: "xmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.footnote.weight(.medium))
            }
            .accessibilityIdentifier(A11yID.Session.searchClearButton)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
    }
}

#Preview("Session") {
    let environment = AppEnvironment.preview()
    return NavigationStack {
        SessionView(session: PreviewData.runningSession, environment: environment)
    }
    .environment(environment)
    .environment(environment.router)
}

#Preview("Session – offline") {
    let environment = AppEnvironment.preview(connection: .disconnected(reason: "Mac asleep"))
    return NavigationStack {
        SessionView(session: PreviewData.permissionSession, environment: environment)
    }
    .environment(environment)
    .environment(environment.router)
}
