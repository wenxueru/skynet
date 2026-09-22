import SwiftUI

/// Root view: adapts to size class, forwards scene phase, and hosts the
/// single navigation structure for each layout.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .task { await environment.bootstrap() }
        .onChange(of: scenePhase) { _, newPhase in
            environment.activityState.isSceneActive = newPhase == .active
        }
    }

    // MARK: - Compact (iPhone): stack navigation

    private var compactLayout: some View {
        @Bindable var router = environment.router
        return NavigationStack(path: $router.compactPath) {
            HomeView(environment: environment)
                .navigationDestination(for: AppDestination.self) { destination in
                    destinationView(destination)
                }
        }
    }

    // MARK: - Regular (iPad): split navigation

    private var regularLayout: some View {
        NavigationSplitView {
            SidebarView(environment: environment)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } content: {
            if let project = environment.router.selectedProject {
                SessionListView(project: project, environment: environment)
                    .id(project.id)
            } else {
                columnPlaceholder(
                    title: "Pick a project",
                    message: "Sessions for the selected project appear here."
                )
            }
        } detail: {
            if let session = environment.router.selectedSession {
                SessionView(session: session, environment: environment)
                    .id(session.id)
            } else {
                columnPlaceholder(
                    title: "Pick a session",
                    message: "Open a session to follow its transcript and send prompts."
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func destinationView(_ destination: AppDestination) -> some View {
        switch destination {
        case .project(let project):
            SessionListView(project: project, environment: environment)
        case .session(let session):
            SessionView(session: session, environment: environment)
                .id(session.id)
        }
    }

    private func columnPlaceholder(title: String, message: String) -> some View {
        EmptyStateView(systemImage: "sidebar.left", title: title, message: message)
            .padding()
    }
}

#Preview("Root – compact") {
    let environment = AppEnvironment.preview()
    return RootView()
        .environment(environment)
        .environment(environment.router)
}

#Preview("Root – regular") {
    let environment = AppEnvironment.preview()
    return RootView()
        .environment(environment)
        .environment(environment.router)
        .environment(\.horizontalSizeClass, .regular)
}
