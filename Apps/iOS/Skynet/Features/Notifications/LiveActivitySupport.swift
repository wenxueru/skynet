import Foundation

/// Live Activity seam. The concrete presenter (ActivityKit-backed, in
/// `TurnActivity.swift`) renders an ongoing turn on the Lock Screen and in
/// Dynamic Island; this protocol keeps the rest of the app free of
/// ActivityKit and makes behavior testable.
public protocol LiveActivityPresenting: Sendable {
    /// Starts (or replaces) the activity for a session's turn.
    func startTurnActivity(sessionID: SessionID, title: String) async
    /// Updates the running turn's state and latest line of progress.
    func updateTurnActivity(state: TurnState, summary: String?) async
    /// Ends the activity for a session.
    func endTurnActivity(sessionID: SessionID) async
}

/// No-op presenter used when Live Activities are unavailable or disabled.
public final class NoopLiveActivityPresenter: LiveActivityPresenting {
    public init() {}

    public func startTurnActivity(sessionID: SessionID, title: String) async {}
    public func updateTurnActivity(state: TurnState, summary: String?) async {}
    public func endTurnActivity(sessionID: SessionID) async {}
}
