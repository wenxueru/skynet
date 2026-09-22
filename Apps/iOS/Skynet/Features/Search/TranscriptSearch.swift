import Foundation

/// Case-insensitive literal match finder over `String`. Foundation-only so it
/// is trivially unit-testable.
public enum TextMatchFinder {
    /// All non-overlapping ranges of `needle` in `haystack`, case- and
    /// diacritic-insensitively. Empty needle yields no matches.
    public static func ranges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty, !haystack.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<haystack.endIndex
              ) {
            result.append(range)
            if range.upperBound == searchStart {
                // Zero-width safety: always advance by one character.
                searchStart = haystack.index(after: range.upperBound)
            } else {
                searchStart = range.upperBound
            }
        }
        return result
    }
}

/// Filters transcript items by a search query and reports match counts.
public struct TranscriptSearch: Sendable {
    public let query: String

    public init(query: String) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isActive: Bool { !query.isEmpty }

    /// Items whose searchable text matches the query, in original order.
    public func apply(to items: [TranscriptItem]) -> [TranscriptItem] {
        guard isActive else { return items }
        return items.filter { matches($0.searchableText) }
    }

    /// Number of matches (not items) across the whole transcript.
    public func matchCount(in items: [TranscriptItem]) -> Int {
        guard isActive else { return 0 }
        return items.reduce(0) { count, item in
            count + TextMatchFinder.ranges(of: query, in: item.searchableText).count
        }
    }

    public func matches(_ text: String) -> Bool {
        guard isActive else { return true }
        return TextMatchFinder.ranges(of: query, in: text).isEmpty == false
    }

    /// Highlights for a specific item's text.
    public func highlightRanges(in text: String) -> [Range<String.Index>] {
        guard isActive else { return [] }
        return TextMatchFinder.ranges(of: query, in: text)
    }
}
