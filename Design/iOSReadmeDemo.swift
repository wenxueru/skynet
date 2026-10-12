import SkynetMobile
import SwiftUI

// Separate executable: production views, synthetic records, memory-only services.
// Never bootstraps production transport, Keychain or notification registration.
@main
struct IOSReadmeDemo: App {
    @State private var environment: AppEnvironment
    @State private var conversation: SessionViewModel
    private let screen: String

    init() {
        screen = ProcessInfo.processInfo.arguments.dropFirst().first ?? "library"
        let machine = Machine(id: MachineID("demo-mac"), displayName: "Studio Mac",
                              modelDescription: "MacBook Pro", osVersion: "macOS", status: .online)
        let project = Project(id: ProjectID("demo-website"), machineID: machine.id,
                              name: "Website", displayPath: "/workspace/website", gitBranch: "main")
        let api = Project(id: ProjectID("demo-api"), machineID: machine.id,
                          name: "API service", displayPath: "/workspace/api", gitBranch: "main")
        let now = Date()
        let session = AgentSession(id: SessionID("demo-onboarding"), projectID: project.id,
                               title: "Simplify onboarding", createdAt: now, updatedAt: now,
                               state: screen == "queue" ? .running : .idle,
                               lastPreview: "A clearer first step. Tests pass.")
        let review = AgentSession(id: SessionID("demo-review"), projectID: project.id,
            title: "Review accessibility", createdAt: now, updatedAt: now,
            lastPreview: "Keyboard navigation and focus states checked.")
        let relay = ScriptedRelay(machineID: machine.id, projects: [project, api], sessions: [session, review],
            history: [session.id: [
                .userMessage(UserMessage(id: TranscriptItemID("demo-user"),
                    text: "Make onboarding simpler. Keep the changes focused and test the flow.", sentAt: now)),
                .assistantMessage(AssistantMessage(id: TranscriptItemID("demo-reply"),
                    text: "A clearer first step\n\nOne primary action, shorter labels, and accessible focus states. Validation stays unchanged.\n\nAll 12 onboarding tests pass. Ready to review.",
                    sentAt: now))
            ]])
        let environment = AppEnvironment(
            relay: relay, pairing: ScriptedPairingService(machine: machine),
            machineStore: InMemoryPairedMachineStore(machines: [machine]),
            notifications: RecordingNotificationScheduler(), liveActivities: NoopLiveActivityPresenter(),
            push: NoopPushTokenRegistrar())
        _environment = State(initialValue: environment)
        let model = SessionViewModel(session: session, relay: relay,
            monitor: environment.monitor, notifications: environment.notifications,
            liveActivities: environment.liveActivities, activityState: environment.activityState)
        if screen == "queue" {
            model.composerDidRequestQueue(PromptPayload(text: "Also check the mobile layout."))
            model.composerDidRequestQueue(PromptPayload(text: "Then summarize the changes for review."))
        }
        _conversation = State(initialValue: model)
    }

    var body: some Scene {
        @Bindable var router = environment.router
        WindowGroup {
            NavigationStack(path: $router.compactPath) {
                if screen == "library" {
                    HomeView(environment: environment)
                        .navigationDestination(for: AppDestination.self) { destination in
                            switch destination {
                            case .project(let project):
                                SessionListView(project: project, environment: environment)
                            case .session(let session):
                                SessionView(session: session, environment: environment)
                            }
                        }
                } else {
                    SessionView(model: conversation, environment: environment)
                }
            }
            .environment(environment)
            .environment(environment.router)
            .tint(Theme.accent)
            .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--light") ? .light : .dark)
            .environment(\.dynamicTypeSize,
                ProcessInfo.processInfo.arguments.contains("--large-type") ? .accessibility2 : .large)
            .task { environment.monitor.start() }
        }
    }

}
