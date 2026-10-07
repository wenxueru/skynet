import AppKit
import SkynetCore
import SwiftUI

/// Owns viewport tracking and history navigation, independent of editor state.
struct SessionTranscriptView: View {
    @Bindable var model: AppModel
    let outlineJump: Jump?
    let onQuote: (String) -> Void
    @State private var isAtBottom = true
    @State private var followsLatestTranscript = true
    @State private var shouldScrollToLatestAfterLoad = false
    @State private var hasInitializedTranscriptPosition = false
    @State private var wasNearTranscriptTop = false
    @State private var isRequestingOlderTranscript = false
    @State private var visibleTranscriptAnchorID: String?

    struct Jump {
        let nonce = UUID()
        let groupID: String
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    Color.clear
                        .frame(height: 1)
                    ForEach(model.transcriptGroups) { group in
                        Group {
                            switch group {
                            case .message(_, let message):
                                TranscriptMessageView(
                                    message: message,
                                    imageData: model.imageData,
                                    onQuote: onQuote
                                )
                            case .tools(_, let steps, let collapseSingle):
                                TranscriptToolRunView(steps: steps, collapseSingle: collapseSingle)
                            }
                        }
                        .id(group.id)
                        .background {
                            GeometryReader { geometry in
                                let frame = geometry.frame(in: .named("transcriptScroll"))
                                Color.clear.preference(
                                    key: TranscriptVisibleAnchorKey.self,
                                    value: frame.maxY > 0
                                        ? TranscriptVisibleAnchor(id: group.id, minY: frame.minY)
                                        : nil
                                )
                            }
                        }
                    }
                    if model.isSelectedSessionRunning {
                        LiveTranscriptResponseView(model: model)
                            .id("live")
                    }
                    Color.clear.frame(height: 1)
                        .padding(.bottom, 24)
                        .id("bottom")
                }
                .frame(maxWidth: 860)
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .frame(maxWidth: .infinity)
                .background {
                    TranscriptScrollObserver(followsLatest: followsLatestTranscript) { nearTop, atBottom, userScrolled in
                        let enteredTop = nearTop && !wasNearTranscriptTop
                        wasNearTranscriptTop = nearTop
                        isAtBottom = atBottom
                        if userScrolled { followsLatestTranscript = atBottom }
                        guard enteredTop, !atBottom,
                              hasInitializedTranscriptPosition,
                              !model.isLoadingTranscript else { return }
                        requestOlderTranscript(using: proxy)
                    }
                }
            }
            .defaultScrollAnchor(.bottom)
            .coordinateSpace(name: "transcriptScroll")
            .onPreferenceChange(TranscriptVisibleAnchorKey.self) { anchor in
                guard visibleTranscriptAnchorID != anchor?.id else { return }
                visibleTranscriptAnchorID = anchor?.id
            }
            .onAppear {
                scrollToLatestOrAfterLoad(using: proxy)
            }
            .onChange(of: model.selectedSessionID) { _, sessionID in
                hasInitializedTranscriptPosition = false
                wasNearTranscriptTop = false
                isRequestingOlderTranscript = false
                visibleTranscriptAnchorID = nil
                guard sessionID != nil else {
                    shouldScrollToLatestAfterLoad = false
                    return
                }
                scrollToLatestOrAfterLoad(using: proxy)
            }
            .onChange(of: model.isLoadingTranscript) { wasLoading, isLoading in
                guard wasLoading, !isLoading, shouldScrollToLatestAfterLoad else { return }
                shouldScrollToLatestAfterLoad = false
                scrollToLatestOrAfterLoad(using: proxy)
            }
            .onChange(of: model.liveText) { _, _ in
                scrollToLatestIfNeeded(using: proxy)
            }
            .onChange(of: model.transcriptGroups.last?.id) { _, _ in
                scrollToLatestIfNeeded(using: proxy)
            }
            .onChange(of: model.liveThinking) { _, _ in
                scrollToLatestIfNeeded(using: proxy)
            }
            .onChange(of: model.liveTools.count) { _, _ in
                scrollToLatestIfNeeded(using: proxy)
            }
            .onChange(of: outlineJump?.nonce) { _, _ in
                guard let groupID = outlineJump?.groupID else { return }
                followsLatestTranscript = false
                withAnimation { proxy.scrollTo(groupID, anchor: .top) }
            }
            .overlay(alignment: .top) {
                if model.canLoadOlderTranscript {
                    Button {
                        requestOlderTranscript(using: proxy)
                    } label: {
                        HStack(spacing: 8) {
                            if model.isLoadingOlderTranscript || isRequestingOlderTranscript {
                                ProgressView().controlSize(.small)
                                Text("Loading older messages…")
                            } else {
                                Text("Load older messages")
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(.quaternary, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("load-older-messages")
                    .disabled(
                        isRequestingOlderTranscript
                            || model.isLoadingOlderTranscript
                            || model.isLoadingTranscript
                    )
                    .padding(.top, 10)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    Button {
                        followsLatestTranscript = true
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } label: {
                        Image(systemName: "chevron.down.2")
                            .font(.title3.weight(.semibold))
                            .frame(width: 42, height: 42)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Jump to latest")
                    .padding(20)
                }
            }
            .overlay {
                if model.isLoadingTranscript {
                    ProgressView().controlSize(.small)
                } else if model.messages.isEmpty, !model.isSelectedSessionRunning {
                    ContentUnavailableView(
                        "No transcript",
                        systemImage: "text.bubble",
                        description: Text("No saved messages yet. Send a message to start the conversation.")
                    )
                }
            }
        }
    }

    private func scrollToLatestIfNeeded(using proxy: ScrollViewProxy) {
        guard followsLatestTranscript else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    private func scrollToLatestOrAfterLoad(using proxy: ScrollViewProxy) {
        guard model.selectedSessionID != nil else { return }
        guard !model.isLoadingTranscript else {
            shouldScrollToLatestAfterLoad = true
            return
        }

        let sessionID = model.selectedSessionID
        followsLatestTranscript = true
        Task { @MainActor in
            await Task.yield()
            guard model.selectedSessionID == sessionID else { return }
            isAtBottom = true
            proxy.scrollTo("bottom", anchor: .bottom)
            hasInitializedTranscriptPosition = true
        }
    }

    private func requestOlderTranscript(using proxy: ScrollViewProxy) {
        guard !isRequestingOlderTranscript,
              !model.isLoadingOlderTranscript,
              !model.isLoadingTranscript,
              model.canLoadOlderTranscript,
              let sessionID = model.selectedSessionID else { return }

        isRequestingOlderTranscript = true
        followsLatestTranscript = false
        let previousVisibleGroupID = visibleTranscriptAnchorID
        Task {
            await model.loadOlderTranscript()
            guard model.selectedSessionID == sessionID else {
                isRequestingOlderTranscript = false
                return
            }

            if let previousVisibleGroupID {
                await Task.yield()
                proxy.scrollTo(previousVisibleGroupID, anchor: .top)
            }
            isRequestingOlderTranscript = false
        }
    }
}


/// Observes the actual clip view: lazy transcript children are not reliable
/// sources of viewport coordinates when they have been recycled offscreen.
struct TranscriptScrollObserver: NSViewRepresentable {
    let followsLatest: Bool
    let onScroll: (Bool, Bool, Bool) -> Void

    func makeNSView(context: Context) -> View {
        let view = View()
        view.followsLatest = followsLatest
        view.onScroll = onScroll
        view.alignToLatestAfterLayout()
        return view
    }

    func updateNSView(_ view: View, context: Context) {
        view.onScroll = onScroll
        view.followsLatest = followsLatest
    }

    final class View: NSView {
        var onScroll: ((Bool, Bool, Bool) -> Void)?
        var followsLatest = false
        private var observers: [NSObjectProtocol] = []
        private weak var observedScrollView: NSScrollView?

        func alignToLatestAfterLayout() {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.alignToLatest()
            }
        }

        private func alignToLatest() {
            guard followsLatest, let scroll = observedScrollView ?? enclosingScrollView,
                  let document = scroll.documentView else { return }
            let clip = scroll.contentView
            let targetY = document.isFlipped
                ? max(0, document.frame.height - clip.bounds.height)
                : 0
            guard abs(clip.bounds.minY - targetY) > 1 else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: targetY))
            scroll.reflectScrolledClipView(clip)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard window != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, let scroll = self.enclosingScrollView else { return }
                self.observedScrollView = scroll
                let clip = scroll.contentView
                clip.postsBoundsChangedNotifications = true
                scroll.documentView?.postsFrameChangedNotifications = true
                if let document = scroll.documentView {
                    self.observers.append(NotificationCenter.default.addObserver(
                        forName: NSView.frameDidChangeNotification, object: document, queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor in self?.alignToLatest() }
                    })
                }
                for (name, object, userScrolled) in [
                    (NSView.boundsDidChangeNotification, clip as AnyObject, false),
                    (NSScrollView.didLiveScrollNotification, scroll as AnyObject, true)
                ] {
                    let observer = NotificationCenter.default.addObserver(
                        forName: name, object: object, queue: .main
                    ) { [weak self, weak scroll] _ in
                        Task { @MainActor in
                            guard let self, let scroll, let document = scroll.documentView else { return }
                            let visible = document.visibleRect
                            let top = document.isFlipped
                                ? visible.minY - document.bounds.minY
                                : document.bounds.maxY - visible.maxY
                            let bottom = document.isFlipped
                                ? document.bounds.maxY - visible.maxY
                                : visible.minY - document.bounds.minY
                            if userScrolled { self.followsLatest = bottom <= 24 }
                            self.onScroll?(top <= 64, bottom <= 24, userScrolled)
                        }
                    }
                    self.observers.append(observer)
                }
                self.alignToLatestAfterLayout()
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

private struct TranscriptVisibleAnchor: Equatable {
    let id: String
    let minY: CGFloat
}

private struct TranscriptVisibleAnchorKey: PreferenceKey {
    static let defaultValue: TranscriptVisibleAnchor? = nil

    static func reduce(value: inout TranscriptVisibleAnchor?, nextValue: () -> TranscriptVisibleAnchor?) {
        guard let candidate = nextValue() else { return }
        guard let current = value else {
            value = candidate
            return
        }
        if candidate.minY < current.minY { value = candidate }
    }
}

