import SwiftUI

/// Small pill-shaped label used for states, counts, and metadata.
public struct BadgeView: View {
    public enum Size {
        case compact
        case regular
    }

    private let text: String
    private let tint: Color
    private let systemImage: String?
    private let size: Size

    public init(
        _ text: String,
        tint: Color,
        systemImage: String? = nil,
        size: Size = .compact
    ) {
        self.text = text
        self.tint = tint
        self.systemImage = systemImage
        self.size = size
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(text)
        }
        .font(size == .compact ? .caption2.weight(.medium) : .footnote.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, size == .compact ? 7 : 10)
        .padding(.vertical, size == .compact ? 3 : 5)
        .background(
            Capsule().fill(tint.opacity(0.14))
        )
        .accessibilityElement(children: .combine)
    }
}

#Preview("Badges") {
    VStack(spacing: 12) {
        BadgeView("Running", tint: .accentColor, systemImage: "bolt.fill")
        BadgeView("42 unread", tint: .blue)
        BadgeView("Offline", tint: .secondary, size: .regular)
    }
    .padding()
}

/// Colored dot indicating liveness; gently pulses while active.
public struct StatusDotView: View {
    private let color: Color
    private let isPulsing: Bool

    @State private var pulsing = false

    public init(color: Color, isPulsing: Bool = false) {
        self.color = color
        self.isPulsing = isPulsing
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay {
                if isPulsing {
                    Circle()
                        .stroke(color.opacity(0.55), lineWidth: 2)
                        .scaleEffect(pulsing ? 2.1 : 1.0)
                        .opacity(pulsing ? 0 : 1)
                        .animation(
                            .easeOut(duration: 1.4).repeatForever(autoreverses: false),
                            value: pulsing
                        )
                }
            }
            .onAppear { pulsing = true }
            .accessibilityHidden(true)
    }
}

#Preview("StatusDot") {
    HStack(spacing: 24) {
        StatusDotView(color: .green, isPulsing: true)
        StatusDotView(color: .orange)
        StatusDotView(color: .secondary)
    }
    .padding()
}
