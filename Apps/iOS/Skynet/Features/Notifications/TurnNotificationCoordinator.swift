import Foundation

/// Decides when agent activity deserves a local notification and schedules
/// it. The app only notifies for events the user did not just watch happen:
/// when the app is backgrounded (or the session's screen is not visible),
/// permission requests and finished turns surface through Notification
/// Center so the user can act from anywhere.
@MainActor
@Observable
public final class TurnNotificationCoordinator {
    private let activity: AppActivityState
    private let scheduler: any AppNotificationScheduling

    public init(activity: AppActivityState, scheduler: any AppNotificationScheduling) {
        self.activity = activity
        self.scheduler = scheduler
    }

    /// True when the user is not looking at the app; only then do events
    /// deserve a notification.
    private var shouldNotify: Bool { !activity.isSceneActive }

    // MARK: - Event intake

    public func turnStarted(session: AgentSession) {
        // Turn starts are intentionally silent; the Live Activity covers
        // in-progress visibility without waking the user.
    }

    public func turnFinished(session: AgentSession, summary: String?) {
        guard shouldNotify else { return }
        let body = summary.map { SkynetFormatters.previewLine(for: $0) }
            ?? "The agent finished working on \(session.title)."
        Task {
            await scheduler.schedule(
                LocalNotificationDescriptor(
                    title: "Turn finished · \(session.title)",
                    body: body,
                    threadIdentifier: session.id.rawValue,
                    sessionID: session.id
                )
            )
        }
    }

    public func permissionRequested(session: AgentSession, request: PermissionRequestRecord) {
        guard shouldNotify else { return }
        Task {
            await scheduler.schedule(
                LocalNotificationDescriptor(
                    title: "Approval needed · \(session.title)",
                    body: request.summary,
                    threadIdentifier: session.id.rawValue,
                    sessionID: session.id
                )
            )
        }
    }

    public func clear(for sessionID: SessionID) {
        Task {
            await scheduler.clearNotifications(for: sessionID)
        }
    }
}
