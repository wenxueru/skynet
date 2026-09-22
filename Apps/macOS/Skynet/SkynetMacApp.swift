import SwiftUI

@main
struct SkynetMacApp: App {
    @State private var model = AppModel()
    @AppStorage(AppPreferenceKey.appearance) private var appearance = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
        }
        .defaultSize(width: 1320, height: 860)

        Settings {
            ProviderSettingsView(model: model)
                .frame(width: 760, height: 560)
                .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
        }
    }
}
