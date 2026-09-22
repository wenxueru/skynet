import Foundation
@preconcurrency import UIKit
import UserNotifications

/// Process-wide pointer to the live environment, set from
/// `AppEnvironment.init`. Delegate callbacks (APNs token, notification taps)
/// can fire before SwiftUI finishes wiring the scene graph, so a static
/// handoff is the one reliable rendezvous point. The reference is weak.
@MainActor
enum AppGlue {
    static weak var environment: AppEnvironment?
}

/// UIKit app delegate retained by SwiftUI's `@UIApplicationDelegateAdaptor`.
/// Forwards APNs registration and silent pushes into the environment's
/// `PushTokenRegistrar` seam.
final class SkynetAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            await AppGlue.environment?.push.registerDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Log.notifications.error("APNs registration failed: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let push = AppGlue.environment?.push else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            await push.handleRemotePayload(userInfo)
            completionHandler(.newData)
        }
    }
}

/// Routes notification taps back into the app: foreground presentations stay
/// quiet (the transcript is the in-app surface), and taps deep-link to the
/// session recorded in `userInfo`.
final class NotificationTapRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationTapRouter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // While the app is foregrounded, in-app surfaces already show the
        // event; avoid double-buzz.
        [.list, .banner]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let rawID = response.notification.request.content.userInfo["sessionID"] as? String else {
            return
        }
        let sessionID = SessionID(rawID)
        await AppGlue.environment?.openSessionFromNotification(sessionID)
    }
}
