import SwiftUI

/// Compact-width root: the machine/project library with the pairing entry
/// point. Pushing a project happens through the shared router (the stack's
/// path lives on `AppRouter`).
struct HomeView: View {
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

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if let loadError = model.loadError {
                BannerView(
                    loadError,
                    style: .warning,
                    actionTitle: "Retry",
                    action: { Task { await model.refresh() } }
                )
                .padding(.horizontal, Theme.Spacing.md)
            }
            ConnectionBannerView(monitor: environment.monitor)
                .padding(.horizontal, Theme.Spacing.md)

            if model.isEmpty && !model.isLoading {
                EmptyStateView(
                    systemImage: "macbook.and.iphone",
                    title: "No Mac paired",
                    message: "Pair a Mac to browse its projects and drive coding sessions from this device.",
                    actionTitle: "Pair a Mac",
                    action: { isPairingPresented = true },
                    actionAccessibilityID: A11yID.Library.emptyPairButton
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LibraryListContent(model: model, selectedProjectID: nil) { project in
                    environment.router.open(project: project)
                }
                .refreshable { await model.refresh() }
            }
        }
        .navigationTitle("Skynet")
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
        .overlay {
            if model.isLoading && model.isEmpty {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $isPairingPresented) {
            PairingView(environment: environment) { _ in
                Task { await model.refresh() }
            }
        }
        .task {
            await model.load()
            // Reload the library whenever the relay comes back — machine
            // status and project activity will have moved on.
            for await connected in environment.monitor.connectedEvents() where connected {
                await model.refresh()
            }
        }
    }
}

#Preview("Home") {
    let environment = AppEnvironment.preview()
    return NavigationStack {
        HomeView(environment: environment)
    }
    .environment(environment)
    .environment(environment.router)
}

#Preview("Home – unpaired") {
    let environment = AppEnvironment.live()
    return NavigationStack {
        HomeView(environment: environment)
    }
    .environment(environment)
    .environment(environment.router)
}
