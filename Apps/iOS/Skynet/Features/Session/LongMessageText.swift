import SwiftUI

/// Assistant/user message body that collapses behind a "Show more" control
/// when it exceeds `LongMessagePolicy` limits. Collapsing is purely a local
/// view concern — the full text always stays in the model.
struct LongMessageText: View {
    private let text: String
    private let query: String?
    private let policy: LongMessagePolicy
    private let itemID: TranscriptItemID

    @State private var isExpanded = false

    init(
        itemID: TranscriptItemID,
        text: String,
        query: String? = nil,
        policy: LongMessagePolicy = .default
    ) {
        self.itemID = itemID
        self.text = text
        self.query = query
        self.policy = policy
    }

    private var shouldCollapse: Bool {
        !isExpanded && policy.shouldCollapse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if shouldCollapse {
                MarkdownText(policy.preview(of: text))
                    .lineLimit(nil)
                    .accessibilityHint("Message truncated. Use Show More to read it all.")

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded = true }
                } label: {
                    Label("Show More", systemImage: "chevron.down")
                        .font(.footnote.weight(.medium))
                }
                .accessibilityIdentifier(A11yID.Session.messageShowMore(itemID))
            } else {
                highlightedBody

                if policy.shouldCollapse(text) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { isExpanded = false }
                    } label: {
                        Label("Show Less", systemImage: "chevron.up")
                            .font(.footnote.weight(.medium))
                    }
                    .accessibilityIdentifier(A11yID.Session.messageShowMore(itemID))
                }
            }
        }
    }

    /// Search highlighting only applies to the expanded body; previews get
    /// plain markdown since their ranges come from the truncated string.
    @ViewBuilder
    private var highlightedBody: some View {
        if let query, !query.isEmpty {
            HighlightedText(text, query: query)
        } else {
            MarkdownText(text)
        }
    }
}

#Preview("Long message") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            LongMessageText(itemID: TranscriptItemID("p1"), text: PreviewData.longReplyText)
            LongMessageText(itemID: TranscriptItemID("p2"), text: "Short and sweet.")
        }
        .padding()
    }
}
