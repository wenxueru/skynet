import SwiftUI

/// Regular-width (iPad) sidebar: the same machine/project library, with the
/// selected project highlighted. Tapping a project updates the router, which
/// drives the split view's content column.
struct SidebarView: View {
    @State private var model: LibraryViewModel
    @State private var isPairingPresented = false

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(
            initialValue: LibraryViewModel(
                machineStore: environment.machineStore,
                pairing: environment.pairing,
                relay: environment.relay,
                sessionIndex: environment.sessionIndex
            )
        )
    }

    private var selectedProjectID: ProjectID? {
        environment.router.selectedProject?.id
    }

    var body: some View {
        Group {
            if model.isEmpty && !model.isLoading {
                EmptyStateView(
                    systemImage: "macbook.and.iphone",
                    title: "No Mac paired",
                    message: "Pair a Mac to browse its projects from this device.",
                    actionTitle: "Pair a Mac",
                    action: { isPairingPresented = true },
                    actionAccessibilityID: A11yID.Library.emptyPairButton
                )
            } else {
                LibraryListContent(model: model, selectedProjectID: selectedProjectID) { project in
                    environment.router.open(project: project)
                }
                .listStyle(.sidebar)
                .refreshable { await model.refresh() }
            }
        }
        .navigationTitle("Skynet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isPairingPresented = true
                } label: {
                    Label("Pair a Mac", systemImage: "plus")
                }
                .accessibilityIdentifier(A11yID.Library.pairButton)
            }
        }
        .sheet(isPresented: $isPairingPresented) {
            PairingView(environment: environment) { _ in
                Task { await model.refresh() }
            }
        }
        .task {
            await model.load()
            for await connected in environment.monitor.connectedEvents() where connected {
                await model.refresh()
            }
        }
    }
}

#Preview("Sidebar") {
    let environment = AppEnvironment.preview()
    return NavigationSplitView {
        SidebarView(environment: environment)
    } detail: {
        Text("Detail")
    }
    .environment(environment)
    .environment(environment.router)
    .environment(\.horizontalSizeClass, .regular)
}
