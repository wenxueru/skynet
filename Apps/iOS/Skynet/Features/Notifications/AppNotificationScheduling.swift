import Foundation
@preconcurrency import UserNotifications

/// Content for a local notification scheduled by the app.
public struct LocalNotificationDescriptor: Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    /// Groups notifications per conversation in Notification Center.
    public var threadIdentifier: String?
    /// Session the notification routes to when tapped.
    public var sessionID: SessionID?
    public var sound: Bool

    public init(
        id: String = UUID().uuidString,
        title: String,
        body: String,
        threadIdentifier: String? = nil,
        sessionID: SessionID? = nil,
        sound: Bool = true
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.threadIdentifier = threadIdentifier
        self.sessionID = sessionID
        self.sound = sound
    }
}

/// Scheduling seam for local notifications. The production implementation
/// wraps `UNUserNotificationCenter`; tests use recording spies.
public protocol AppNotificationScheduling: Sendable {
    /// Requests (or checks) authorization. Returns the granted state.
    @discardableResult
    func requestAuthorization() async -> Bool
    func schedule(_ descriptor: LocalNotificationDescriptor) async
    /// Removes delivered and pending notifications for a session.
    func clearNotifications(for sessionID: SessionID) async
}

/// `UNUserNotificationCenter`-backed scheduler. `@unchecked Sendable`
/// because the center is documented thread-safe.
public final class UserNotificationsScheduler: AppNotificationScheduling, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()

    public init() {}

    public func requestAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        @unknown default:
            return false
        }
    }

    public func schedule(_ descriptor: LocalNotificationDescriptor) async {
        let content = UNMutableNotificationContent()
        content.title = descriptor.title
        content.body = descriptor.body
        if let threadIdentifier = descriptor.threadIdentifier {
            content.threadIdentifier = threadIdentifier
        }
        if descriptor.sound {
            content.sound = .default
        }
        if let sessionID = descriptor.sessionID {
            content.userInfo = ["sessionID": sessionID.rawValue]
        }
        let request = UNNotificationRequest(
            identifier: descriptor.id,
            content: content,
            trigger: nil // deliver immediately
        )
        do {
            try await center.add(request)
        } catch {
            Log.notifications.error("Failed to schedule notification: \(error.localizedDescription)")
        }
    }

    public func clearNotifications(for sessionID: SessionID) async {
        let delivered = await center.deliveredNotifications()
        let identifiers = delivered
            .filter { $0.request.content.userInfo["sessionID"] as? String == sessionID.rawValue }
            .map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
