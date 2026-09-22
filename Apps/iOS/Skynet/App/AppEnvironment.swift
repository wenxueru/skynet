import Foundation
import SwiftUI
import UserNotifications

/// Composition root. Everything transport-shaped is a protocol so the
/// integration layer can swap in the real paired-Mac relay (or a SkynetCore
/// bridge) without touching feature code. `live()` provides safe
/// placeholders until that wiring exists.
@MainActor
@Observable
public final class AppEnvironment {
    public let relay: any SkynetRelay
    public let pairing: any PairingService
    public let machineStore: any PairedMachineStore
    public let notifications: any AppNotificationScheduling
    public let liveActivities: any LiveActivityPresenting
    public let push: any PushTokenRegistrar

    public let router = AppRouter()
    public let sessionIndex = SessionIndex()
    public let activityState = AppActivityState()
    public let monitor: ConnectionMonitorModel

    public init(
        relay: any SkynetRelay,
        pairing: any PairingService,
        machineStore: any PairedMachineStore,
        notifications: any AppNotificationScheduling,
        liveActivities: any LiveActivityPresenting,
        push: any PushTokenRegistrar
    ) {
        self.relay = relay
        self.pairing = pairing
        self.machineStore = machineStore
        self.notifications = notifications
        self.liveActivities = liveActivities
        self.push = push
        self.monitor = ConnectionMonitorModel(relay: relay)
        // Registered before any delegate callback can fire; AppDelegate and
        // the notification tap router forward into the environment.
        AppGlue.environment = self
    }

    /// Production composition. Pass overrides when integrating the real
    /// transport:
    ///
    /// ```swift
    /// AppEnvironment.live(
    ///     relay: MyPairedMacRelay(...),
    ///     pairing: RelayPairingService(...)
    /// )
    /// ```
    public static func live(
        relay: (any SkynetRelay)? = nil,
        pairing: (any PairingService)? = nil,
        machineStore: (any PairedMachineStore)? = nil,
        notifications: (any AppNotificationScheduling)? = nil,
        liveActivities: (any LiveActivityPresenting)? = nil,
        push: (any PushTokenRegistrar)? = nil
    ) -> AppEnvironment {
        AppEnvironment(
            relay: relay ?? UnpairedRelay(),
            pairing: pairing ?? UnconfiguredPairingService(),
            machineStore: machineStore ?? KeychainPairedMachineStore(),
            notifications: notifications ?? UserNotificationsScheduler(),
            liveActivities: liveActivities ?? NoopLiveActivityPresenter(),
            push: push ?? NoopPushTokenRegistrar()
        )
    }

    /// Launch-time setup: connection observation, notification permission,
    /// push registration, tap routing. Called once from the root view.
    public func bootstrap() async {
        monitor.start()
        UNUserNotificationCenter.current().delegate = NotificationTapRouter.shared
        Task {
            _ = await notifications.requestAuthorization()
            await push.enableRemoteNotifications()
        }
    }

    /// Deep link from a notification tap into a session, when known.
    public func openSessionFromNotification(_ sessionID: SessionID) async {
        guard let session = await sessionIndex.lookup(session: sessionID) else {
            Log.navigation.info("Notification tap for unknown session \(sessionID.rawValue)")
            return
        }
        router.open(session: session)
    }
}
