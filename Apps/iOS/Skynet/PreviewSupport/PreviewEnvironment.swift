import Foundation

extension AppEnvironment {
    /// Fully scripted environment for previews and UI-test fixtures:
    /// two machines (one offline), two projects, three sessions, and a rich
    /// transcript wired to the relay.
    public static func preview(
        connection: ConnectionState = .connected
    ) -> AppEnvironment {
        let relay = PreviewData.scriptedRelay(connection: connection)
        let store = InMemoryPairedMachineStore(
            machines: [PreviewData.machine, PreviewData.offlineMachine]
        )
        return AppEnvironment(
            relay: relay,
            pairing: ScriptedPairingService(machine: PreviewData.machine),
            machineStore: store,
            notifications: RecordingNotificationScheduler(),
            liveActivities: NoopLiveActivityPresenter(),
            push: NoopPushTokenRegistrar()
        )
    }
}
