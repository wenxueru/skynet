import SwiftUI

/// Renders `text` with every case-insensitive occurrence of `query`
/// highlighted. Used by transcript search.
public struct HighlightedText: View {
    private let text: String
    private let query: String
    private let highlightColor: Color

    public init(_ text: String, query: String, highlightColor: Color = .yellow) {
        self.text = text
        self.query = query
        self.highlightColor = highlightColor
    }

    public var body: some View {
        let matches = query.isEmpty ? [] : TextMatchFinder.ranges(of: query, in: text)
        Text(Self.highlighted(text: text, matches: matches, color: highlightColor))
    }

    /// Builds the final attributed string from precomputed match ranges.
    public static func highlighted(
        text: String,
        matches: [Range<String.Index>],
        color: Color
    ) -> AttributedString {
        var result = AttributedString()
        var cursor = text.startIndex
        for match in matches {
            if cursor < match.lowerBound {
                result.append(AttributedString(String(text[cursor..<match.lowerBound])))
            }
            var hit = AttributedString(String(text[match]))
            hit.backgroundColor = color.opacity(0.45)
            hit.font = .body.weight(.semibold)
            result.append(hit)
            cursor = match.upperBound
        }
        if cursor < text.endIndex {
            result.append(AttributedString(String(text[cursor..<text.endIndex])))
        }
        return result
    }
}

#Preview("HighlightedText") {
    HighlightedText("Fix the flaky test in TranscriptViewTests", query: "test")
        .padding()
}

/// Assistant message body rendered as markdown with monospaced inline code.
/// Degrades gracefully to plain text while a streaming prefix is not yet
/// valid markdown.
public struct MarkdownText: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(Self.attributed(from: text))
    }

    public static func attributed(from text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        var attributed: AttributedString
        do {
            attributed = try AttributedString(markdown: text, options: options)
        } catch {
            attributed = AttributedString(text)
        }
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attributed[run.range].font = Theme.monoFootnote
            }
        }
        return attributed
    }
}

#Preview("MarkdownText") {
    VStack(alignment: .leading, spacing: 12) {
        MarkdownText("The fix is in `SessionView.swift`, method `applyDelta`.")
        MarkdownText("Run the suite with `npm test -- --watch` after pulling.")
    }
    .padding()
}

/// Three bouncing dots shown while an assistant message streams in.
public struct StreamingIndicator: View {
    @State private var phase = false

    public init() {}

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 6, height: 6)
                    .offset(y: phase ? -3 : 2)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.12),
                        value: phase
                    )
            }
        }
        .onAppear { phase = true }
        .accessibilityLabel("Agent is responding")
        .accessibilityIdentifier("session.streaming-indicator")
    }
}

#Preview("StreamingIndicator") {
    StreamingIndicator().padding()
}
