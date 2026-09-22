import SwiftUI

/// The scrolling transcript: lazy rows, bottom-anchored autoscroll, a
/// jump-to-latest button, and (optionally) search-filtered display with
/// highlighted matches.
struct TranscriptView: View {
    let items: [TranscriptItem]
    /// Active search query; nil disables filtering/highlighting.
    var search: TranscriptSearch? = nil
    var onPermissionDecision: ((PermissionRequestRecord, PermissionDecision) -> Void)? = nil
    var isStreaming = false

    private static let bottomAnchor = "transcript-bottom-anchor"

    @State private var isAtBottom = true
    @Namespace private var scrollNamespace

    private var isSearching: Bool {
        search?.isActive == true
    }

    private var displayedItems: [TranscriptItem] {
        guard let search else { return items }
        return search.apply(to: items)
    }

    private var lastItemID: TranscriptItemID? {
        displayedItems.last?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.md) {
                    ForEach(displayedItems) { item in
                        TranscriptRow(
                            item: item,
                            highlightQuery: isSearching ? search?.query : nil,
                            onPermissionDecision: onPermissionDecision
                        )
                        .id(item.id.rawValue)
                    }

                    if displayedItems.isEmpty {
                        if isSearching {
                            Text("No matches for “\(search?.query ?? "")”")
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                                .padding(.top, Theme.Spacing.xl)
                        } else {
                            EmptyStateView(
                                systemImage: "bubble.left.and.text.bubble.right",
                                title: "No messages yet",
                                message: "Send a prompt below to start the conversation."
                            )
                            .accessibilityIdentifier(A11yID.Session.emptyState)
                        }
                    }

                    // Bottom sentinel: presence drives `isAtBottom`.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                        .onAppear { isAtBottom = true }
                        .onDisappear { isAtBottom = false }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.md)
                .padding(.bottom, Theme.Spacing.lg)
            }
            .defaultScrollAnchor(.bottom)
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom && !isSearching {
                    JumpToBottomButton(unreadCount: 0) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                        }
                    }
                    .padding(Theme.Spacing.md)
                }
            }
            .onChange(of: items.count) { _, _ in
                guard !isSearching else { return }
                if isAtBottom {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }
            }
            .onChange(of: displayedItems.last?.id) { _, _ in
                guard !isSearching, isAtBottom else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
        .accessibilityIdentifier(A11yID.Session.transcript)
    }
}

#Preview("Transcript") {
    TranscriptView(
        items: PreviewData.transcript,
        onPermissionDecision: nil
    )
}

#Preview("Transcript – searching") {
    TranscriptView(
        items: PreviewData.transcript,
        search: TranscriptSearch(query: "test"),
        onPermissionDecision: nil
    )
}
