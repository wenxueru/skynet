import SwiftUI

/// Floating "back to latest" affordance shown while the reader has scrolled
/// up; carries an unread badge when new items arrived out of view.
struct JumpToBottomButton: View {
    var unreadCount: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .padding(Theme.Spacing.md)
                .background(.thinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .overlay(alignment: .topTrailing) {
                    if unreadCount > 0 {
                        Text("\(min(unreadCount, 99))")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Theme.accent, in: Circle())
                            .offset(x: 6, y: -6)
                    }
                }
        }
        .accessibilityLabel("Jump to latest messages")
        .accessibilityIdentifier(A11yID.Session.jumpToBottomButton)
        .transition(.scale.combined(with: .opacity))
    }
}

#Preview("Jump to bottom") {
    VStack {
        Spacer()
        HStack {
            Spacer()
            JumpToBottomButton(unreadCount: 3, action: {})
                .padding()
        }
    }
}
