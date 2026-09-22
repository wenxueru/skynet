import Foundation

/// Centralized formatting helpers so list rows and transcript timestamps stay
/// consistent. All pure Foundation — directly unit-testable.
public enum SkynetFormatters {
    /// Relative time like “just now”, “12m ago”, “3h ago”, “yesterday”.
    public static func relativeTime(
        _ date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 45 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days)d ago" }
        let comps = calendar.dateComponents([.year, .month, .day], from: date, to: now)
        if let years = comps.year, years >= 1 {
            return "\(years)y ago"
        }
        if let months = comps.month, months >= 1 {
            return "\(months)mo ago"
        }
        return "\(days / 7)w ago"
    }

    /// Compact duration for tool calls: “420ms”, “1.2s”, “2m 05s”.
    public static func duration(_ interval: TimeInterval) -> String {
        guard interval >= 0 else { return "0ms" }
        if interval < 1 {
            return "\(Int((interval * 1000).rounded()))ms"
        }
        if interval < 60 {
            return String(format: "%.1fs", interval)
        }
        let minutes = Int(interval / 60)
        let seconds = Int(interval.truncatingRemainder(dividingBy: 60))
        return String(format: "%dm %02ds", minutes, seconds)
    }

    /// Human-readable byte counts for attachments: “1.2 MB”.
    public static func byteCount(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// One-line preview text for a transcript item in session lists.
    public static func previewLine(for text: String, limit: Int = 90) -> String {
        let flattened = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened[..<flattened.index(flattened.startIndex, offsetBy: limit)]) + "…"
    }
}
