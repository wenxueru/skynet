import Foundation
import SkynetCore
import Testing

@Suite("Session date grouping")
struct SessionDateGroupingTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(identifier: "UTC")!
        return value
    }

    private func date(_ day: Int, month: Int = 9, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test func groupsAcrossProjectsInGlobalRecencyOrder() {
        let old = SessionRecord(providerID: .codex, updatedAt: date(12))
        let today = SessionRecord(providerID: .claudeCode, updatedAt: date(18))
        let yesterday = SessionRecord(providerID: .codex, updatedAt: date(17))
        let groups = SessionDateGrouping.groups(
            [old, today, yesterday], now: date(18), calendar: calendar
        )

        #expect(groups.map(\.title) == ["Today", "Yesterday", "Sep 12"])
        #expect(groups.flatMap(\.sessions).map(\.id) == [today.id, yesterday.id, old.id])
    }

    @Test func weekdaysAndOlderYearsMatchOriginalBuckets() {
        let monday = SessionRecord(providerID: .codex, updatedAt: date(14))
        let previousYear = SessionRecord(providerID: .codex, updatedAt: date(20, year: 2025))
        let groups = SessionDateGrouping.groups(
            [previousYear, monday], now: date(18), calendar: calendar
        )

        #expect(groups.map(\.title) == ["Monday", "Sep 20, 2025"])
    }
}
