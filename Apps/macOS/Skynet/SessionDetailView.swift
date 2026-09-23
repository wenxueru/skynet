import AppKit
import SkynetCore
import SwiftUI
import UniformTypeIdentifiers

struct SessionDetailView: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @State private var title = ""
    @State private var isImageImporterPresented = false
    @State private var isAtBottom = true
    @State private var transcriptViewportHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            composer
        }
        .onAppear { title = model.selectedSession?.title ?? "New session" }
        .onChange(of: model.selectedSessionID) { _, _ in
            title = model.selectedSession?.title ?? "New session"
        }
        .fileImporter(
            isPresented: $isImageImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                urls.forEach(model.attachImage)
            }
        }
    }

    private var header: some View {
        HStack {
            TextField("Session name", text: $title)
                .textFieldStyle(.plain)
                .font(.headline)
                .multilineTextAlignment(.center)
                .onSubmit { model.renameSelectedSession(title) }
            if model.isRunning {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(model.messages) { message in
                        TranscriptMessageView(message: message)
                            .id(message.id.description)
                    }
                    if model.isRunning {
                        LiveTranscriptResponseView(model: model)
                            .id("live")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: BottomPositionKey.self,
                                    value: geometry.frame(in: .named("transcriptScroll")).maxY
                                )
                            }
                        }
                }
                .frame(maxWidth: 860)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "transcriptScroll")
            .onPreferenceChange(BottomPositionKey.self) { bottomPosition in
                isAtBottom = bottomPosition <= transcriptViewportHeight + 24
            }
            .onChange(of: model.liveText) { _, _ in
                scrollToLatestIfNeeded(using: proxy)
            }
            .onChange(of: model.liveThinking) { _, _ in
                scrollToLatestIfNeeded(using: proxy)
            }
            .onChange(of: model.liveTools.count) { _, _ in
                scrollToLatestIfNeeded(using: proxy)
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    Button {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
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
                } else if model.messages.isEmpty, !model.isRunning {
                    ContentUnavailableView(
                        "No transcript",
                        systemImage: "text.bubble",
                        description: Text("This session only contains metadata; Claude Code did not save any messages.")
                    )
                }
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { transcriptViewportHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, height in
                            transcriptViewportHeight = height
                        }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !model.pendingAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(model.pendingAttachments) { attachment in
                            AttachmentThumbnail(attachment: attachment) {
                                model.removeAttachment(attachment.id)
                            }
                        }
                    }
                }
                .frame(height: 64)
            }

            VStack(spacing: 8) {
                ComposerTextView(text: $draft, onSend: submit)
                    .frame(minHeight: 48, maxHeight: 130)

                HStack {
                    Button { isImageImporterPresented = true } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("Attach image")

                    Spacer()
                    modelMenu
                    effortMenu
                    Button(action: model.isRunning ? model.cancel : submit) {
                        Image(systemName: model.isRunning ? "stop.fill" : "arrow.up")
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(model.isRunning ? .red : .blue, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.isRunning && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingAttachments.isEmpty)
                }
            }
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
        .frame(maxWidth: 860)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var modelMenu: some View {
        Menu {
            if let provider = model.selectedProvider {
                Button("Provider default") { model.updateModel(nil) }
                Divider()
                ForEach(provider.resolvedModelCatalog.models, id: \.id) { candidate in
                    Button(candidate.displayName) { model.updateModel(candidate.id) }
                }
            }
        } label: {
            Text(selectedModelName).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var effortMenu: some View {
        Menu {
            Button("Auto") { model.updateEffort(nil) }
            ForEach(supportedEfforts, id: \.self) { effort in
                Button(effort.displayName) { model.updateEffort(effort) }
            }
        } label: {
            Text(model.selectedSession?.effort?.displayName ?? "Auto")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var selectedModelName: String {
        guard let provider = model.selectedProvider else { return "Default model" }
        guard let id = model.selectedSession?.modelID else { return "Default model" }
        return provider.resolvedModelCatalog.model(with: id)?.displayName ?? id.rawValue
    }

    private var supportedEfforts: [ReasoningEffort] {
        guard let provider = model.selectedProvider,
              let id = model.selectedSession?.modelID else { return ReasoningEffort.allCases }
        return provider.resolvedModelCatalog.model(with: id)?.supportedEfforts ?? ReasoningEffort.allCases
    }

    private func submit() {
        let prompt = draft
        guard !model.isRunning else { return }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.pendingAttachments.isEmpty else { return }
        draft = ""
        model.send(prompt)
    }

    private func scrollToLatestIfNeeded(using proxy: ScrollViewProxy) {
        guard isAtBottom else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }
}

private struct BottomPositionKey: PreferenceKey {
    static let defaultValue = CGFloat.infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct AttachmentThumbnail: View {
    let attachment: ImageAttachment
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if case .inline(let data, _) = attachment.payload, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 58, height: 58).clipped()
            }
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
