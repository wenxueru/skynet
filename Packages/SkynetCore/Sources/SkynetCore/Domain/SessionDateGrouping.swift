import Foundation

public struct SessionDateGroup: Sendable {
    public let title: String
    public var sessions: [SessionRecord]

    public init(title: String, sessions: [SessionRecord]) {
        self.title = title
        self.sessions = sessions
    }
}

/// Global recent-activity buckets shared by local and remote sessions.
public enum SessionDateGrouping {
    public static func groups(
        _ sessions: [SessionRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [SessionDateGroup] {
        let ordered = sessions.sorted {
            $0.updatedAt == $1.updatedAt
                ? $0.id.description < $1.id.description
                : $0.updatedAt > $1.updatedAt
        }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start
        let currentYear = calendar.component(.year, from: today)

        func formatter(_ template: String) -> DateFormatter {
            let value = DateFormatter()
            value.calendar = calendar
            value.locale = calendar.locale ?? .current
            value.timeZone = calendar.timeZone
            value.setLocalizedDateFormatFromTemplate(template)
            return value
        }
        let weekday = formatter("EEEE")
        let date = formatter("MMMd")
        let dateWithYear = formatter("yMMMd")

        func title(for updatedAt: Date) -> String {
            let day = calendar.startOfDay(for: min(updatedAt, now))
            if day >= today { return "Today" }
            if day >= yesterday { return "Yesterday" }
            if let weekStart, day >= weekStart { return weekday.string(from: day) }
            return calendar.component(.year, from: day) == currentYear
                ? date.string(from: day) : dateWithYear.string(from: day)
        }

        var result: [SessionDateGroup] = []
        for session in ordered {
            let heading = title(for: session.updatedAt)
            if result.last?.title == heading {
                result[result.count - 1].sessions.append(session)
            } else {
                result.append(SessionDateGroup(title: heading, sessions: [session]))
            }
        }
        return result
    }
}
