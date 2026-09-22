import SwiftUI

/// App entry point. All services are protocol-fronted; see `AppEnvironment`
/// for where the integration layer swaps in the real paired-Mac relay.
@main
struct SkynetApp: App {
    @UIApplicationDelegateAdaptor(SkynetAppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(environment.router)
        }
    }
}
