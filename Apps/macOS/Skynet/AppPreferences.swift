import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppPreferenceKey {
    static let appearance = "appearance"
    static let showTimestamps = "showMessageTimestamps"
    static let expandReasoning = "expandReasoningByDefault"
    static let expandTools = "expandToolDetailsByDefault"
}
