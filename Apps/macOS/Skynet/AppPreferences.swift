import AppKit
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

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static func apply(_ rawValue: String) {
        NSApp.appearance = (AppAppearance(rawValue: rawValue) ?? .system).nsAppearance
    }
}

enum AppPreferenceKey {
    static let appearance = "appearance"
    static let showTimestamps = "showMessageTimestamps"
    static let expandReasoning = "expandReasoningByDefault"
    static let expandTools = "expandToolDetailsByDefault"
}
