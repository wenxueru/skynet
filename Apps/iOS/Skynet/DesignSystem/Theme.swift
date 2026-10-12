import SkynetMobile
import SwiftUI
import UIKit

/// Semantic design tokens for the app. Built on system colors so the app
/// follows light/dark mode and accessibility settings automatically; the
/// few custom colors are dynamic-provider based.
public enum Theme {
    // MARK: Spacing & shape

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
    }

    public enum Radius {
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 18
        public static let pill: CGFloat = 999
    }

    // MARK: Colors

    /// Shared blue accent, with contrast tuned for each appearance.
    public static let accent = adaptiveColor(
        light: UIColor(red: 0.10, green: 0.36, blue: 0.78, alpha: 1),
        dark: UIColor(red: 0.40, green: 0.66, blue: 1.0, alpha: 1))

    public static let success = adaptiveColor(
        light: UIColor(red: 0.13, green: 0.55, blue: 0.28, alpha: 1),
        dark: UIColor(red: 0.42, green: 0.80, blue: 0.48, alpha: 1))

    public static let warning = adaptiveColor(
        light: UIColor(red: 0.72, green: 0.51, blue: 0.05, alpha: 1),
        dark: UIColor(red: 0.95, green: 0.76, blue: 0.31, alpha: 1))

    public static let danger = adaptiveColor(
        light: UIColor(red: 0.75, green: 0.19, blue: 0.17, alpha: 1),
        dark: UIColor(red: 0.96, green: 0.51, blue: 0.48, alpha: 1))

    /// Bubble backgrounds for chat rows.
    public static let userBubble = adaptiveColor(
        light: UIColor(red: 0.89, green: 0.94, blue: 1.0, alpha: 1),
        dark: UIColor(red: 0.12, green: 0.22, blue: 0.37, alpha: 1))

    public static let assistantBubble = adaptiveColor(
        light: UIColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1),
        dark: UIColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1))

    public static let toolCallBackground = adaptiveColor(
        light: UIColor(red: 0.965, green: 0.965, blue: 0.97, alpha: 1),
        dark: UIColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1))

    public static let codeBackground = adaptiveColor(
        light: UIColor(red: 0.93, green: 0.94, blue: 0.95, alpha: 1),
        dark: UIColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1))

    private static func adaptiveColor(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    // MARK: Typography

    public static let monoFootnote = Font.system(.footnote, design: .monospaced)
    public static let monoCaption = Font.system(.caption2, design: .monospaced)

    /// Color for a tool call state.
    public static func color(for state: ToolCallState) -> Color {
        switch state {
        case .running: return accent
        case .succeeded: return success
        case .failed: return danger
        case .canceled: return Color.secondary
        }
    }

    /// Color for a machine/session status.
    public static func color(for state: TurnState) -> Color {
        switch state {
        case .idle: return Color.secondary
        case .running: return accent
        case .awaitingPermission: return warning
        case .canceling: return warning
        case .failed: return danger
        }
    }

    /// Icon for a tool kind.
    public static func systemImage(for kind: ToolKind) -> String {
        switch kind {
        case .shell: return "terminal"
        case .fileEdit: return "pencil.and.list.clipboard"
        case .fileRead: return "doc.text"
        case .search: return "magnifyingglass"
        case .web: return "globe"
        case .other: return "wrench.and.screwdriver"
        }
    }
}
