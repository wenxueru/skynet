import AppKit
import SkynetCore
import SwiftUI

struct TranscriptMessageView: View {
    let message: Message
    let imageData: (ImageAttachment) -> Data?
    let onQuote: (String) -> Void
    @AppStorage(AppPreferenceKey.showTimestamps) private var showTimestamps = true

    var body: some View {
        HStack(alignment: .top) {
            if message.origin == .user { Spacer(minLength: 96) }
            VStack(alignment: message.origin == .user ? .trailing : .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(message.content.indices, id: \.self) { index in
                        TranscriptBlockView(
                            block: message.content[index],
                            rendersMarkdown: message.origin != .user,
                            imageData: imageData
                        )
                    }
                }
                .padding(message.origin == .user ? 14 : 0)
                .background(message.origin == .user ? Color.accentColor.opacity(0.14) : .clear)
                .clipShape(.rect(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 5, topTrailingRadius: 16))

                HStack(spacing: 8) {
                    if showTimestamps || message.modelID != nil || message.usage?.totalTokens != nil {
                        MessageMetadata(message: message)
                    }
                    Menu {
                        messageActions
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Message actions")
                }
            }
            .contextMenu {
                messageActions
            }
            if message.origin != .user { Spacer(minLength: 96) }
        }
    }

    @ViewBuilder
    private var messageActions: some View {
        if !message.plainText.isEmpty {
            Button("Copy text") { NSPasteboard.general.setString(message.plainText) }
            Button("Quote in composer") {
                onQuote(message.plainText.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }.joined(separator: "\n"))
            }
            ShareLink(item: message.plainText) {
                Label("Share text…", systemImage: "square.and.arrow.up")
            }
        }
        Button("Copy message ID") {
            NSPasteboard.general.setString(message.id.description)
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
    let imageData: (ImageAttachment) -> Data?

    var body: some View {
        switch block {
        case .text(let text):
            CollapsibleTextView(text: text, rendersMarkdown: rendersMarkdown)
        case .thinking(let text, _):
            ReasoningBlockView(text: text)
        case .image(let attachment):
            AttachmentImageView(attachment: attachment, imageData: imageData)
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
            ForEach(segments.indices, id: \.self) { index in
                switch segments[index] {
                case .prose(let text):
                    (Text("\u{200A}") + Text(text) + Text("\u{200A}"))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        // Bold CJK glyphs and Markdown list markers can extend
                        // slightly outside Text's reported bounds. The hair
                        // spaces keep those glyphs away from Text's own clip.
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                case .heading(let level, let text):
                    Text(text)
                        .font(level <= 2 ? .title3.bold() : .headline)
                        .textSelection(.enabled)
                        .padding(.top, level <= 2 ? 6 : 2)
                case .listItem(let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(marker).frame(minWidth: 18, alignment: .trailing)
                        Text(text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 8)
                case .quote(let text):
                    Text(text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(.tertiary).frame(width: 3)
                        }
                        .foregroundStyle(.secondary)
                case .equation(let equation):
                    Text(equation)
                        .font(.system(.title3, design: .serif))
                        .italic()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                case .fileCitation(let path):
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    } label: {
                        Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "doc.fill")
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                case .followup(let title):
                    Label(title, systemImage: "circle.fill")
                        .labelStyle(FollowupLabelStyle())
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                case .table(let table):
                    MarkdownTableView(table: table)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum MarkdownSegment {
    case prose(AttributedString)
    case heading(level: Int, text: AttributedString)
    case listItem(marker: String, text: AttributedString)
    case quote(AttributedString)
    case equation(String)
    case fileCitation(path: String)
    case followup(title: String)
    case code(language: String?, content: String)
    case table(MarkdownTable)

    static func parse(_ source: String) -> [MarkdownSegment] {
        let lines = source.components(separatedBy: .newlines)
        var segments: [MarkdownSegment] = []
        var buffer: [String] = []
        var language: String?
        var equation: [String]?
        var nextUnparsedLine = 0

        func flushProse() {
            guard !buffer.isEmpty else { return }
            segments.append(.prose(attributed(buffer.joined(separator: " "))))
            buffer.removeAll(keepingCapacity: true)
        }

        for index in lines.indices {
            guard index >= nextUnparsedLine else { continue }
            let line = lines[index]
            if equation != nil {
                if line.trimmingCharacters(in: .whitespaces) == #"\]"# {
                    segments.append(.equation(formatEquation(equation!.joined(separator: " "))))
                    equation = nil
                } else {
                    equation!.append(line)
                }
                continue
            }
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
            } else if language != nil {
                buffer.append(line)
            } else if line.trimmingCharacters(in: .whitespaces) == #"\["# {
                flushProse()
                equation = []
            } else if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flushProse()
            } else if let parsed = MarkdownTable.parse(lines, startingAt: index) {
                flushProse()
                segments.append(.table(parsed.table))
                nextUnparsedLine = parsed.nextLineIndex
            } else if let citation = capture(citationRegex, in: line) {
                let prefix = line.components(separatedBy: ":codex-file-citation").first ?? ""
                if !prefix.trimmingCharacters(in: .whitespaces).isEmpty { buffer.append(prefix) }
                flushProse()
                segments.append(.fileCitation(path: citation))
            } else if let title = capture(followupRegex, in: line) {
                flushProse()
                segments.append(.followup(title: title))
            } else if let heading = heading(in: line) {
                flushProse()
                segments.append(.heading(level: heading.level, text: attributed(heading.text)))
            } else if let item = orderedItem(in: line) {
                flushProse()
                segments.append(.listItem(marker: "\(item.number).", text: attributed(item.text)))
            } else if let item = unorderedItem(in: line) {
                flushProse()
                segments.append(.listItem(marker: "•", text: attributed(item)))
            } else if let quote = capture(quoteRegex, in: line) {
                flushProse()
                segments.append(.quote(attributed(quote)))
            } else {
                buffer.append(line)
            }
        }
        if let equation {
            segments.append(.equation(formatEquation(equation.joined(separator: " "))))
        } else if let language {
            segments.append(.code(language: language, content: buffer.joined(separator: "\n")))
        } else {
            flushProse()
        }
        return segments.isEmpty ? [.prose(attributed(source))] : segments
    }

    static func attributed(_ source: String) -> AttributedString {
        let source = replacingInlineEquations(in: source)
        return (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func orderedItem(in line: String) -> (number: Int, text: String)? {
        guard let match = firstMatch(of: orderedItemRegex, in: line),
              let markerRange = Range(match.range(at: 1), in: line),
              let itemRange = Range(match.range(at: 0), in: line),
              let number = Int(line[markerRange]) else { return nil }
        return (number, String(line[itemRange.upperBound...]))
    }

    private static func unorderedItem(in line: String) -> String? {
        guard let match = firstMatch(of: unorderedItemRegex, in: line),
              let range = Range(match.range(at: 0), in: line) else { return nil }
        return String(line[range.upperBound...])
    }

    private static func capture(_ regex: NSRegularExpression, in source: String) -> String? {
        guard let match = firstMatch(of: regex, in: source),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }

    private static func firstMatch(
        of regex: NSRegularExpression,
        in source: String
    ) -> NSTextCheckingResult? {
        regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source))
    }

    private static func replacingInlineEquations(in source: String) -> String {
        var result = source
        for match in inlineEquationRegex.matches(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        ).reversed() {
            guard let whole = Range(match.range(at: 0), in: result),
                  let body = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(whole, with: formatEquation(String(result[body])))
        }
        return result
    }

    private static func formatEquation(_ source: String) -> String {
        var result = source
            .replacingOccurrences(of: #"\rightarrow"#, with: "→")
            .replacingOccurrences(of: #"\tilde A"#, with: "Ã")
        while let match = firstMatch(of: textCommandRegex, in: result),
              let whole = Range(match.range(at: 0), in: result),
              let body = Range(match.range(at: 1), in: result) {
            let replacement = String(result[body])
            result.replaceSubrange(whole, with: replacement)
        }
        result = replacingScripts(in: result, marker: "_", symbols: subscriptSymbols)
        result = replacingScripts(in: result, marker: "^", symbols: superscriptSymbols)
        return result.replacingOccurrences(of: "  ", with: " ")
    }

    private static func replacingScripts(
        in source: String,
        marker: Character,
        symbols: [Character: Character]
    ) -> String {
        let escapedMarker = NSRegularExpression.escapedPattern(for: String(marker))
        guard let regex = try? NSRegularExpression(
            pattern: escapedMarker + #"(?:\{([^}]*)\}|([A-Za-z0-9,+\-=()]))"#
        ) else { return source }
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let whole = Range(match.range(at: 0), in: result) else { continue }
            let captureIndex = match.range(at: 1).location != NSNotFound ? 1 : 2
            guard let bodyRange = Range(match.range(at: captureIndex), in: result) else { continue }
            let body = result[bodyRange]
            let converted = String(body.map { symbols[$0] ?? $0 })
            result.replaceSubrange(whole, with: converted)
        }
        return result
    }

    private static let subscriptSymbols: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ",
        "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ",
        "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ",
        "v": "ᵥ", "x": "ₓ", "+": "₊", "-": "₋", "=": "₌",
        "(": "₍", ")": "₎",
    ]

    private static let superscriptSymbols: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ",
        "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ",
        "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ",
        "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ",
        "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
    ]

    private static let citationRegex = regex(#":codex-file-citation\{path="([^"]+)"[^}]*\}"#)
    private static let followupRegex = regex(#":codex-followup\[([^]]+)\]"#)
    private static let quoteRegex = regex(#"^\s*>\s?(.*)$"#)
    private static let orderedItemRegex = regex(#"^\s*(\d+)\.\s+"#)
    private static let unorderedItemRegex = regex(#"^\s*[-*+]\s+"#)
    private static let inlineEquationRegex = regex(#"\\\((.+?)\\\)"#)
    private static let textCommandRegex = regex(#"\\text\{([^}]*)\}"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // All patterns are static literals covered by the renderer's build tests.
        try! NSRegularExpression(pattern: pattern)
    }
}

private struct FollowupLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.font(.system(size: 6))
            configuration.title
        }
        .padding(.leading, 8)
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

private struct MarkdownTableView: View {
    let table: MarkdownTable
    private let renderedHeaders: [AttributedString]
    private let renderedRows: [[AttributedString]]
    private let columnWidths: [CGFloat]

    init(table: MarkdownTable) {
        self.table = table
        renderedHeaders = table.headers.map(MarkdownSegment.attributed)
        renderedRows = table.rows.map { $0.map(MarkdownSegment.attributed) }

        var longestCells = table.headers.map(\.count)
        for row in table.rows {
            for column in row.indices {
                longestCells[column] = max(longestCells[column], row[column].count)
            }
        }
        columnWidths = longestCells.map { min(max(CGFloat($0) * 8, 140), 320) }
    }

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                row(renderedHeaders)
                    .fontWeight(.semibold)
                    .padding(.vertical, 9)
                    .background(Color(nsColor: .controlBackgroundColor))
                ForEach(renderedRows.indices, id: \.self) { index in
                    Divider()
                    row(renderedRows[index])
                        .padding(.vertical, 9)
                }
            }
            .padding(.horizontal, 12)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    private func row(_ cells: [AttributedString]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(table.headers.indices, id: \.self) { column in
                Text(cells[column])
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: columnWidths[column], alignment: alignment(for: column))
            }
        }
    }

    private func alignment(for column: Int) -> Alignment {
        switch table.alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
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
    let imageData: (ImageAttachment) -> Data?

    var body: some View {
        if let data = imageData(attachment), let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 440)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Label("Image unavailable", systemImage: "photo")
                .foregroundStyle(.secondary)
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
            ToolCallDetailView(call: call, fallback: formattedInput)
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

private struct ToolCallDetailView: View {
    let call: ToolCall
    let fallback: String

    private var name: String { call.name.lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let plan = call.input["plan"]?.arrayValue, !plan.isEmpty {
                ForEach(plan.indices, id: \.self) { index in
                    let item = plan[index]
                    Label {
                        Text(item["step"]?.stringValue ?? item["content"]?.stringValue ?? "Step \(index + 1)")
                    } icon: {
                        Image(systemName: item["status"]?.stringValue == "completed"
                              ? "checkmark.circle.fill" : "circle")
                    }
                    .font(.caption)
                }
            } else if let questions = call.input["questions"]?.arrayValue, !questions.isEmpty {
                ForEach(questions.indices, id: \.self) { index in
                    let question = questions[index]
                    Text(question["question"]?.stringValue ?? "Question \(index + 1)")
                        .font(.caption.weight(.semibold))
                    if let options = question["options"]?.arrayValue {
                        ForEach(options.indices, id: \.self) { optionIndex in
                            Text("• " + (options[optionIndex]["label"]?.stringValue ?? "Option"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let old = call.input["old_string"]?.stringValue,
                      let new = call.input["new_string"]?.stringValue {
                diffBlock(old, color: .red, prefix: "−")
                diffBlock(new, color: .green, prefix: "+")
            } else if let edits = call.input["edits"]?.arrayValue, !edits.isEmpty {
                ForEach(edits.indices, id: \.self) { index in
                    let edit = edits[index]
                    Text("Edit \(index + 1)").font(.caption.weight(.semibold))
                    if let old = edit["old_string"]?.stringValue {
                        diffBlock(old, color: .red, prefix: "−")
                    }
                    if let new = edit["new_string"]?.stringValue {
                        diffBlock(new, color: .green, prefix: "+")
                    }
                }
            } else if let changes = call.input["changes"]?.objectValue, !changes.isEmpty {
                ForEach(changes.keys.sorted(), id: \.self) { path in
                    Label(path, systemImage: "doc.badge.ellipsis")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    if let patch = changes[path]?.stringValue {
                        diffBlock(patch, color: .secondary, prefix: "")
                    }
                }
            } else if let patch = call.input["unified_diff"]?.stringValue
                        ?? call.input["patch"]?.stringValue
                        ?? call.input["patches"]?.stringValue {
                let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        let text = String(lines[index])
                        Text(text.isEmpty ? " " : text)
                            .foregroundStyle(text.hasPrefix("+") ? .green
                                : text.hasPrefix("-") ? .red : .secondary)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(7)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            } else if let prompt = call.input["prompt"]?.stringValue,
                      name.contains("task") || name.contains("agent") {
                Text(prompt)
                    .font(.callout)
                    .textSelection(.enabled)
            } else if let command = call.input["command"]?.stringValue
                        ?? call.input["cmd"]?.stringValue {
                Text("$ " + command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Text(fallback)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func diffBlock(_ text: String, color: Color, prefix: String) -> some View {
        ScrollView(.horizontal) {
            Text(prefix + text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
        .padding(7)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct ToolResultCard: View {
    let content: String
    let isError: Bool
    @AppStorage(AppPreferenceKey.expandTools) private var expandByDefault = false
    @State private var expanded: Bool?
    @State private var showsFullOutput = false

    private var isLong: Bool { content.count > 8_000 }
    private var visibleOutput: String {
        isLong && !showsFullOutput ? String(content.prefix(6_000)) + "\n…" : content
    }

    var body: some View {
        DisclosureGroup(isExpanded: binding) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if isLong {
                        Button(showsFullOutput ? "Show less" : "Show full output") {
                            showsFullOutput.toggle()
                        }
                    }
                    Spacer()
                    Button("Copy output", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(content, forType: .string)
                    }
                    .labelStyle(.iconOnly)
                }
                .font(.caption2)
                ScrollView(.horizontal) {
                    Text(visibleOutput)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(isError ? .red : .primary)
                    .textSelection(.enabled)
                }
            }
            .padding(.top, 8)
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

struct TranscriptToolRunView: View {
    let steps: [TranscriptToolStep]
    let collapseSingle: Bool
    @State private var expanded = false

    private var summary: TranscriptRunSummary { TranscriptRunSummary(steps: steps) }

    var body: some View {
        Group {
            if steps.count == 1 && !collapseSingle {
                step(steps[0])
            } else {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(steps.indices, id: \.self) { index in
                            step(steps[index])
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 8) {
                        Label(summary.title, systemImage: summary.icon)
                            .font(.callout)
                        Text(summary.detail)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        if summary.hasError {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.red)
                                .accessibilityLabel("Tool failed")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 860, alignment: .leading)
    }

    private func step(_ step: TranscriptToolStep) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let call = step.call { ToolCallCard(call: call) }
            if let result = step.result {
                ToolResultCard(content: result, isError: step.isError)
            }
        }
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
        } else if name.contains("plan") || name.contains("todo") {
            icon = "checklist"
            title = "Plan"
            subtitle = call.input["plan"]?.arrayValue.map { "\($0.count) steps" }
        } else if name.contains("question") || name.contains("input") {
            icon = "questionmark.bubble"
            title = "Asked a question"
            subtitle = nil
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
