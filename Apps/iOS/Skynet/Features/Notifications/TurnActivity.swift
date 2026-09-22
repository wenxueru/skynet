import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(ActivityKit)

/// Live Activity attributes for an in-flight agent turn. The static part is
/// the session title; the dynamic part is the turn state and a one-line
/// summary of what the agent is doing.
public struct TurnActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var stateTitle: String
        public var summary: String?

        public init(stateTitle: String, summary: String?) {
            self.stateTitle = stateTitle
            self.summary = summary
        }
    }

    public var sessionTitle: String

    public init(sessionTitle: String) {
        self.sessionTitle = sessionTitle
    }
}

/// `LiveActivityPresenting` backed by ActivityKit. Live Activities are
/// best-effort: disabled, unsupported, or authorization-denied states all
/// degrade to a no-op rather than an error path.
@MainActor
public final class ActivityKitLiveActivityPresenter: LiveActivityPresenting {
    private var activityID: Activity<TurnActivityAttributes>.ID?

    public init() {}

    public func startTurnActivity(sessionID: SessionID, title: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Log.notifications.debug("Live activities are not enabled; skipping turn activity")
            return
        }
        await endTurnActivity(sessionID: sessionID)

        let attributes = TurnActivityAttributes(sessionTitle: title)
        let initial = ActivityContent(
            state: TurnActivityAttributes.ContentState(stateTitle: "Working", summary: nil),
            staleDate: nil
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: initial
            )
            activityID = activity.id
        } catch {
            Log.notifications.error("Failed to start turn activity: \(error.localizedDescription)")
        }
    }

    public func updateTurnActivity(state: TurnState, summary: String?) async {
        guard let activityID,
              let activity = Activity<TurnActivityAttributes>.activities
                  .first(where: { $0.id == activityID }) else {
            return
        }
        let content = ActivityContent(
            state: TurnActivityAttributes.ContentState(
                stateTitle: state.displayName,
                summary: summary.map { SkynetFormatters.previewLine(for: $0, limit: 60) }
            ),
            staleDate: nil
        )
        await activity.update(content)
    }

    public func endTurnActivity(sessionID: SessionID) async {
        guard let activityID else { return }
        self.activityID = nil
        for activity in Activity<TurnActivityAttributes>.activities where activity.id == activityID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

#else

/// Fallback when ActivityKit is unavailable (e.g. macOS destinations in
/// previews). The real protocol default, `NoopLiveActivityPresenter`, serves
/// the same purpose for tests.
public typealias ActivityKitLiveActivityPresenter = NoopLiveActivityPresenter

#endif
