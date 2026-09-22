import AppKit
import SkynetCore
import SwiftUI
import UniformTypeIdentifiers

struct SessionDetailView: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @State private var title = ""
    @State private var isImageImporterPresented = false

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
                        MessageView(message: message)
                            .id(message.id.description)
                    }
                    if model.isRunning {
                        LiveResponseView(model: model)
                            .id("live")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 860)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.liveText) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                } label: {
                    Image(systemName: "chevron.down.2")
                        .font(.title3.weight(.semibold))
                        .frame(width: 42, height: 42)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(20)
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
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
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
}

private struct MessageView: View {
    let message: Message

    var body: some View {
        HStack {
            if message.origin == .user { Spacer(minLength: 100) }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(message.content.enumerated()), id: \.offset) { _, block in
                    ContentBlockView(block: block)
                }
            }
            .padding(message.origin == .user ? 14 : 0)
            .background(message.origin == .user ? Color.accentColor.opacity(0.18) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            if message.origin != .user { Spacer(minLength: 100) }
        }
    }
}

private struct ContentBlockView: View {
    let block: ContentBlock
    @State private var expanded = false

    var body: some View {
        switch block {
        case .text(let text):
            VStack(alignment: .leading) {
                Text(expanded || text.count < 2200 ? text : String(text.prefix(1200)) + "…")
                    .textSelection(.enabled)
                if text.count >= 2200 {
                    Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                        .buttonStyle(.link)
                }
            }
        case .thinking(let text, _):
            DisclosureGroup("Reasoning") { Text(text).textSelection(.enabled) }
                .foregroundStyle(.secondary)
        case .image(let attachment):
            if case .inline(let data, _) = attachment.payload, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        case .toolCall(let call):
            DisclosureGroup("Tool: \(call.name)") {
                Text(pretty(call.input)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        case .toolResult(_, let content, let isError):
            DisclosureGroup(isError ? "Tool failed" : "Tool result") {
                Text(content).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
    }
}

private struct LiveResponseView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = Int(context.date.timeIntervalSince(model.workingSince ?? context.date))
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working for \(max(0, seconds))s")
                        .foregroundStyle(.secondary)
                }
            }
            if !model.liveThinking.isEmpty {
                DisclosureGroup("Reasoning") { Text(model.liveThinking).textSelection(.enabled) }
            }
            if !model.liveText.isEmpty { Text(model.liveText).textSelection(.enabled) }
            ForEach(model.liveTools) { tool in
                DisclosureGroup(tool.output == nil ? "Running \(tool.name)" : tool.name) {
                    Text(tool.output ?? pretty(tool.input))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

private func pretty(_ value: JSONValue) -> String {
    guard let data = try? JSONEncoder().encode(value),
          let object = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
        return String(describing: value)
    }
    return String(decoding: pretty, as: UTF8.self)
}
