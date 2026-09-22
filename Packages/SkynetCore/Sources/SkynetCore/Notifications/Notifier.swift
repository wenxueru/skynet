import Foundation

/// A user-facing notification, derived from agent events.
///
/// The core decides *when* something is worth interrupting the user; the
/// app decides *how* it is delivered (UserNotifications framework,
/// a badge, a sound). Triggers are deliberately coarse — content of the
/// conversation is never copied into a notification body beyond what the
/// session title already exposes.
public struct SkynetNotification: Hashable, Sendable {
    public enum Trigger: String, Hashable, Sendable, CaseIterable {
        case turnCompleted
        case turnFailed
        case permissionRequired
    }

    public var id: UUID
    public var trigger: Trigger
    public var title: String
    public var body: String
    public var sessionID: SessionID?
    public var projectID: ProjectID?
    public var date: Date

    public init(
        id: UUID = UUID(),
        trigger: Trigger,
        title: String,
        body: String,
        sessionID: SessionID? = nil,
        projectID: ProjectID? = nil,
        date: Date = Date()
    ) {
        self.id = id
        self.trigger = trigger
        self.title = title
        self.body = body
        self.sessionID = sessionID
        self.projectID = projectID
        self.date = date
    }
}

/// Delivers notifications. Implemented by the apps on top of their
/// platform's notification framework; `RecordingNotifier` records for
/// tests.
public protocol Notifier: Sendable {
    func notify(_ notification: SkynetNotification) async
}

/// Decides which events become notifications.
public struct NotificationRouting: Sendable {
    /// Triggers allowed to interrupt the user. Defaults are quiet: only
    /// failures and permission asks notify.
    public var enabledTriggers: Set<SkynetNotification.Trigger>

    public init(enabledTriggers: Set<SkynetNotification.Trigger> = [.turnFailed, .permissionRequired]) {
        self.enabledTriggers = enabledTriggers
    }

    /// Maps an event to a notification, or `nil` when it should not
    /// interrupt. Pure — safe to unit test exhaustively.
    public func notification(
        for event: AgentEvent,
        session: SessionRecord,
        project: Project?
    ) -> SkynetNotification? {
        let trigger: SkynetNotification.Trigger
        let body: String
        switch event {
        case .turnCompleted(let summary):
            guard enabledTriggers.contains(.turnCompleted) else { return nil }
            trigger = .turnCompleted
            body = summary.finalText ?? "Turn finished."
        case .turnFailed(let failure):
            guard enabledTriggers.contains(.turnFailed) else { return nil }
            trigger = .turnFailed
            body = failure.error.localizedDescription
        case .permissionRequested(let request):
            guard enabledTriggers.contains(.permissionRequired) else { return nil }
            trigger = .permissionRequired
            body = request.summary
        default:
            return nil
        }

        let subject = project?.name ?? session.title ?? "Agent"
        let title: String
        switch trigger {
        case .turnCompleted: title = "\(subject) finished"
        case .turnFailed: title = "\(subject) needs attention"
        case .permissionRequired: title = "\(subject) asks permission"
        }

        return SkynetNotification(
            trigger: trigger,
            title: title,
            body: body.isEmpty ? " " : body,
            sessionID: session.id,
            projectID: session.projectID ?? project?.id,
            date: Date()
        )
    }
}

/// Watches an event stream and fans notifications out to notifiers.
public struct EventNotificationRouter: Sendable {
    public var routing: NotificationRouting
    public var notifiers: [any Notifier]

    public init(
        routing: NotificationRouting = NotificationRouting(),
        notifiers: [any Notifier] = []
    ) {
        self.routing = routing
        self.notifiers = notifiers
    }

    /// Feed one event through the routing table. Call for every event of
    /// every session; cheap when nothing matches.
    public func handle(
        _ event: AgentEvent,
        session: SessionRecord,
        project: Project? = nil
    ) async {
        guard
            let notification = routing.notification(
                for: event,
                session: session,
                project: project
            )
        else { return }
        for notifier in notifiers {
            await notifier.notify(notification)
        }
    }
}
