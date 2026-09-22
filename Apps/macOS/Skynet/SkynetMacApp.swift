import SwiftUI

@main
struct SkynetMacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1320, height: 860)

        Settings {
            ProviderSettingsView(model: model)
                .frame(width: 560, height: 480)
        }
    }
}
