import Foundation

/// Shared, app-scoped view of "is the UI in front of the user right now".
/// Scene phase flows in from the root view; notification decisions read it.
@MainActor
@Observable
public final class AppActivityState {
    public var isSceneActive = true

    public init() {}
}
