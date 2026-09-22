import AppKit
import SkynetCore
import SwiftUI

struct TranscriptMessageView: View {
    let message: Message
    @AppStorage(AppPreferenceKey.showTimestamps) private var showTimestamps = true

    var body: some View {
        HStack(alignment: .top) {
            if message.origin == .user { Spacer(minLength: 96) }
            VStack(alignment: message.origin == .user ? .trailing : .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(message.content.enumerated()), id: \.offset) { _, block in
                        TranscriptBlockView(block: block, rendersMarkdown: message.origin != .user)
                    }
                }
                .padding(message.origin == .user ? 14 : 0)
                .background(message.origin == .user ? Color.accentColor.opacity(0.14) : .clear)
                .clipShape(.rect(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 5, topTrailingRadius: 16))

                if showTimestamps || message.modelID != nil || message.usage?.totalTokens != nil {
                    MessageMetadata(message: message)
                }
            }
            .contextMenu {
                if !message.plainText.isEmpty {
                    Button("Copy") { NSPasteboard.general.setString(message.plainText) }
                }
            }
            if message.origin != .user { Spacer(minLength: 96) }
        }
    }
}

private struct MessageMetadata: View {
    let message: Message
    @AppStorage(AppPreferenceKey.showTimestamps) private var showTimestamps = true

    var body: some View {
        HStack(spacing: 6) {
            if showTimestamps { Text(message.createdAt, style: .time) }
            if let model = message.modelID { Text(model.rawValue) }
            if let tokens = message.usage?.totalTokens { Text("\(tokens.formatted()) tokens") }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

private struct TranscriptBlockView: View {
    let block: ContentBlock
    let rendersMarkdown: Bool

    var body: some View {
        switch block {
        case .text(let text):
            CollapsibleTextView(text: text, rendersMarkdown: rendersMarkdown)
        case .thinking(let text, _):
            ReasoningBlockView(text: text)
        case .image(let attachment):
            AttachmentImageView(attachment: attachment)
        case .toolCall(let call):
            ToolCallCard(call: call)
        case .toolResult(_, let content, let isError):
            ToolResultCard(content: content, isError: isError)
        }
    }
}

private struct CollapsibleTextView: View {
    let text: String
    let rendersMarkdown: Bool
    @State private var expanded = false

    private var isLong: Bool { text.count > 2_400 }
    private var visibleText: String {
        guard isLong, !expanded else { return text }
        return String(text.prefix(1_400)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rendersMarkdown {
                MarkdownContentView(markdown: visibleText)
            } else {
                Text(verbatim: visibleText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isLong {
                Button(expanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
                .buttonStyle(.link)
                .font(.footnote)
            }
        }
    }
}

private struct MarkdownContentView: View {
    private let segments: [MarkdownSegment]

    init(markdown: String) {
        segments = MarkdownRenderCache.segments(for: markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let text):
                    Text(text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        // Bold CJK glyphs and Markdown list markers can extend
                        // slightly outside Text's reported bounds.
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum MarkdownSegment {
    case prose(AttributedString)
    case code(language: String?, content: String)

    static func parse(_ source: String) -> [MarkdownSegment] {
        let lines = source.components(separatedBy: .newlines)
        var segments: [MarkdownSegment] = []
        var buffer: [String] = []
        var language: String?

        func flushProse() {
            guard !buffer.isEmpty else { return }
            segments.append(.prose(attributed(buffer.joined(separator: "\n"))))
            buffer.removeAll(keepingCapacity: true)
        }

        for line in lines {
            if line.hasPrefix("```") {
                if language == nil {
                    flushProse()
                    let label = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    language = label.isEmpty ? "Code" : label
                } else {
                    segments.append(.code(language: language, content: buffer.joined(separator: "\n")))
                    buffer.removeAll(keepingCapacity: true)
                    language = nil
                }
            } else {
                buffer.append(line)
            }
        }
        if let language {
            segments.append(.code(language: language, content: buffer.joined(separator: "\n")))
        } else {
            flushProse()
        }
        return segments.isEmpty ? [.prose(attributed(source))] : segments
    }

    private static func attributed(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(source)
    }
}

@MainActor
private enum MarkdownRenderCache {
    private static let cache: NSCache<NSString, Document> = {
        let cache = NSCache<NSString, Document>()
        cache.countLimit = 256
        return cache
    }()

    static func segments(for markdown: String) -> [MarkdownSegment] {
        let key = markdown as NSString
        if let document = cache.object(forKey: key) { return document.segments }

        let document = Document(segments: MarkdownSegment.parse(markdown))
        cache.setObject(document, forKey: key)
        return document.segments
    }

    private final class Document {
        let segments: [MarkdownSegment]

        init(segments: [MarkdownSegment]) {
            self.segments = segments
        }
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "Code").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { NSPasteboard.general.setString(code) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }
}

private struct ReasoningBlockView: View {
    let text: String
    @AppStorage(AppPreferenceKey.expandReasoning) private var expandByDefault = false
    @State private var expanded: Bool?

    var body: some View {
        DisclosureGroup(isExpanded: binding) {
            MarkdownContentView(markdown: text)
                .opacity(0.72)
                .padding(.leading, 8)
                .padding(.top, 4)
        } label: {
            Label("Reasoning", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var binding: Binding<Bool> { expansionBinding($expanded, fallback: expandByDefault) }
}

private struct AttachmentImageView: View {
    let attachment: ImageAttachment

    var body: some View {
        if case .inline(let data, _) = attachment.payload, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 440)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct ToolCallCard: View {
    let call: ToolCall
    private let formattedInput: String
    private let summary: ToolSummary
    @AppStorage(AppPreferenceKey.expandTools) private var expandByDefault = false
    @State private var expanded: Bool?

    init(call: ToolCall) {
        self.call = call
        formattedInput = prettyJSON(call.input)
        summary = ToolSummary(call: call)
    }

    var body: some View {
        DisclosureGroup(isExpanded: binding) {
            Text(formattedInput)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.top, 8)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: summary.icon).frame(width: 18).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title).font(.callout.weight(.medium))
                    if let subtitle = summary.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(11)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var binding: Binding<Bool> { expansionBinding($expanded, fallback: expandByDefault) }
}

private struct ToolResultCard: View {
    let content: String
    let isError: Bool
    @AppStorage(AppPreferenceKey.expandTools) private var expandByDefault = false
    @State private var expanded: Bool?

    var body: some View {
        DisclosureGroup(isExpanded: binding) {
            ScrollView(.horizontal) {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(isError ? .red : .primary)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }
        } label: {
            Label(isError ? "Tool failed" : "Tool completed", systemImage: isError ? "xmark.circle" : "checkmark.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(isError ? .red : .secondary)
        }
        .padding(.horizontal, 11)
    }

    private var binding: Binding<Bool> {
        expansionBinding($expanded, fallback: expandByDefault || isError)
    }
}

struct LiveTranscriptResponseView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = Int(context.date.timeIntervalSince(model.workingSince ?? context.date))
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working for \(max(0, seconds))s").foregroundStyle(.secondary)
                }
            }
            if !model.liveThinking.isEmpty { ReasoningBlockView(text: model.liveThinking) }
            if !model.liveText.isEmpty { MarkdownContentView(markdown: model.liveText) }
            ForEach(model.liveTools) { tool in
                VStack(alignment: .leading, spacing: 6) {
                    ToolCallCard(call: ToolCall(id: tool.id, name: tool.name, input: tool.input))
                    if let output = tool.output { ToolResultCard(content: output, isError: tool.isError) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToolSummary {
    let icon: String
    let title: String
    let subtitle: String?

    init(call: ToolCall) {
        let name = call.name.lowercased()
        let target = Self.firstString(in: call.input, keys: ["file_path", "path", "file", "notebook_path"])
        let command = Self.firstString(in: call.input, keys: ["cmd", "command"])
        if name.contains("read") || name == "view_image" {
            icon = name == "view_image" ? "photo" : "eye"
            title = target.map { "Read · \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Read"
            subtitle = nil
        } else if name.contains("edit") || name.contains("patch") {
            icon = "pencil"
            title = target.map { "Edit · \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Edit"
            subtitle = nil
        } else if name.contains("write") {
            icon = "square.and.pencil"
            title = target.map { "Write · \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Write"
            subtitle = nil
        } else if command != nil || name.contains("exec") || name.contains("bash") {
            icon = "terminal"
            title = "Run command"
            subtitle = command?.split(whereSeparator: \.isNewline).first.map(String.init)
        } else if name.contains("wait") {
            icon = "hourglass"
            title = "Wait for result"
            subtitle = nil
        } else {
            icon = "wrench.and.screwdriver"
            title = call.name
            subtitle = target
        }
    }

    private static func firstString(in value: JSONValue, keys: [String]) -> String? {
        keys.lazy.compactMap { value[$0]?.stringValue }.first
    }
}

private func prettyJSON(_ value: JSONValue) -> String {
    guard let data = try? JSONEncoder().encode(value),
          let object = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
        return String(describing: value)
    }
    return String(decoding: pretty, as: UTF8.self)
}

private func expansionBinding(_ value: Binding<Bool?>, fallback: Bool) -> Binding<Bool> {
    Binding(get: { value.wrappedValue ?? fallback }, set: { value.wrappedValue = $0 })
}

private extension NSPasteboard {
    func setString(_ value: String) {
        clearContents()
        setString(value, forType: .string)
    }
}
