import SwiftUI

@main
struct SkynetMacApp: App {
    @State private var model = AppModel()
    @AppStorage(AppPreferenceKey.appearance) private var appearance = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { AppAppearance.apply(appearance) }
                .onChange(of: appearance) { _, value in AppAppearance.apply(value) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 860)

        Settings {
            ProviderSettingsView(model: model)
                .frame(width: 760, height: 560)
                .onAppear { AppAppearance.apply(appearance) }
                .onChange(of: appearance) { _, value in AppAppearance.apply(value) }
        }
    }
}
