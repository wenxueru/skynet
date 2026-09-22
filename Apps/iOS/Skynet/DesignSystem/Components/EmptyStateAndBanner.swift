import SwiftUI

/// Reusable empty/placeholder state with an optional action.
public struct EmptyStateView: View {
    private let systemImage: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?
    private let actionAccessibilityID: String?

    public init(
        systemImage: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        actionAccessibilityID: String? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.actionAccessibilityID = actionAccessibilityID
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.secondary)
                .accessibilityHidden(true)
            VStack(spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .modifier(OptionalAccessibilityID(id: actionAccessibilityID))
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Applies an accessibility identifier only when one is provided.
struct OptionalAccessibilityID: ViewModifier {
    let id: String?

    func body(content: Content) -> some View {
        if let id {
            content.accessibilityIdentifier(id)
        } else {
            content
        }
    }
}

#Preview("EmptyState") {
    EmptyStateView(
        systemImage: "macbook.and.ipad",
        title: "No Mac paired",
        message: "Pair a Mac to start driving coding sessions from this device.",
        actionTitle: "Pair a Mac"
    )
}

/// Inline banner for connectivity and error surfaces.
public struct BannerView: View {
    public enum Style {
        case info
        case warning
        case error

        var tint: Color {
            switch self {
            case .info: return Theme.accent
            case .warning: return Theme.warning
            case .error: return Theme.danger
            }
        }

        var systemImage: String {
            switch self {
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "wifi.exclamationmark"
            }
        }
    }

    private let text: String
    private let style: Style
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        _ text: String,
        style: Style,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.text = text
        self.style = style
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: style.systemImage)
                .foregroundStyle(style.tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(style.tint)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(style.tint.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Banner") {
    VStack(spacing: 12) {
        BannerView("Reconnecting to Mac…", style: .warning, actionTitle: "Retry", action: {})
        BannerView("Connection lost", style: .error)
        BannerView("Queued prompts will send when reconnected", style: .info)
    }
    .padding()
}
