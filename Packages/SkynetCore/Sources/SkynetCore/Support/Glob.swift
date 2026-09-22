import Foundation

/// Minimal glob matching shared by the permission rule engine.
///
/// Supported syntax:
/// - `*` — any run of characters, including none
/// - `?` — exactly one character
/// - everything else — literal, case-sensitive
///
/// No regex, no character classes: patterns are user-facing configuration
/// and must stay predictable.
public enum Glob {
    /// Returns `true` when `value` matches `pattern`.
    public static func matches(_ pattern: String, value: String) -> Bool {
        let patternChars = Array(pattern)
        let valueChars = Array(value)

        var patternIndex = 0
        var valueIndex = 0
        var starPatternIndex = -1
        var starValueIndex = 0

        while valueIndex < valueChars.count {
            if patternIndex < patternChars.count, patternChars[patternIndex] == "*" {
                starPatternIndex = patternIndex
                starValueIndex = valueIndex
                patternIndex += 1
            } else if
                patternIndex < patternChars.count,
                patternChars[patternIndex] == "?"
                    || patternChars[patternIndex] == valueChars[valueIndex]
            {
                patternIndex += 1
                valueIndex += 1
            } else if starPatternIndex != -1 {
                // Backtrack: the `*` swallows one more character.
                patternIndex = starPatternIndex + 1
                starValueIndex += 1
                valueIndex = starValueIndex
            } else {
                return false
            }
        }

        while patternIndex < patternChars.count, patternChars[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == patternChars.count
    }

    /// `true` when the pattern contains no wildcards and therefore matches
    /// at most one string.
    public static func isExact(_ pattern: String) -> Bool {
        !pattern.contains("*") && !pattern.contains("?")
    }
}
