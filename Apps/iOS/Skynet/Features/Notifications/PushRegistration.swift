import Foundation

/// Remote-notification seam. The iOS side only registers and forwards
/// tokens/payloads; the relay on the paired Mac (or a server component)
/// decides when to send pushes. Integrators swap in an APNs-backed
/// implementation that also registers the token with the relay.
public protocol PushTokenRegistrar: Sendable {
    /// Called once at launch to enable remote notifications.
    func enableRemoteNotifications() async
    /// Called with the APNs device token after registration succeeds.
    func registerDeviceToken(_ token: Data) async
    /// Called when a silent push arrives while the app is running.
    func handleRemotePayload(_ payload: [AnyHashable: Any]) async
}

/// Placeholder registrar: registration is a no-op until integration wires
/// APNs and the relay's token registry.
public final class NoopPushTokenRegistrar: PushTokenRegistrar {
    public init() {}

    public func enableRemoteNotifications() async {}
    public func registerDeviceToken(_ token: Data) async {}
    public func handleRemotePayload(_ payload: [AnyHashable: Any]) async {}
}
