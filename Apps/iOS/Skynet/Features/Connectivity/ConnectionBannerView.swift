import SwiftUI

/// Inline connectivity banner. Reads the shared connection monitor; hidden
/// while connected so it takes no space in the happy path.
public struct ConnectionBannerView: View {
    @Bindable var monitor: ConnectionMonitorModel

    public init(monitor: ConnectionMonitorModel) {
        self.monitor = monitor
    }

    public var body: some View {
        switch monitor.state {
        case .connected:
            EmptyView()
        case .connecting:
            BannerView(
                monitor.reconnectAttempt > 0
                    ? "Reconnecting to your Mac… (attempt \(monitor.reconnectAttempt))"
                    : "Connecting to your Mac…",
                style: .warning,
                actionTitle: "Retry Now",
                action: { Task { await monitor.reconnectNow() } }
            )
            .accessibilityIdentifier(A11yID.Connectivity.banner)
        case .disconnected(let reason):
            BannerView(
                "Connection lost. \(reason ?? "Unknown reason")",
                style: .error,
                actionTitle: "Retry",
                action: { Task { await monitor.reconnectNow() } }
            )
            .accessibilityIdentifier(A11yID.Connectivity.banner)
        }
    }
}

#Preview("Connection banners") {
    let connectingMonitor = ConnectionMonitorModel(relay: PreviewData.scriptedRelay(connection: .connecting))
    let offlineMonitor = ConnectionMonitorModel(
        relay: PreviewData.scriptedRelay(connection: .disconnected(reason: "The relay is unreachable"))
    )
    return VStack(spacing: Theme.Spacing.md) {
        ConnectionBannerView(monitor: connectingMonitor)
        ConnectionBannerView(monitor: offlineMonitor)
    }
    .padding()
    .task {
        connectingMonitor.start()
        offlineMonitor.start()
    }
}
