import Foundation
import SkynetCore
import Testing

@Suite("Session usage summary")
struct SessionUsageSummaryTests {
    @Test func prefersTurnUsageAndGroupsByDayAgentAndModel() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let session = SessionRecord(
            providerID: .codex,
            modelID: ModelID("fallback"),
            updatedAt: now,
            totalUsage: TokenUsage(inputTokens: 999)
        )
        let message = Message(
            origin: .agent,
            content: [.text("Done")],
            createdAt: now,
            modelID: ModelID("actual"),
            usage: TokenUsage(inputTokens: 10, cacheReadTokens: 5, outputTokens: 2)
        )
        let result = SessionUsageSummary.summarize(
            [(session: session, messages: [message])], range: .all, now: now
        )
        #expect(result.totals.totalTokens == 17)
        #expect(result.totals.requests == 1)
        #expect(result.byAgent.map(\.key) == ["codex"])
        #expect(result.byModel.map(\.key) == ["actual"])
        #expect(result.daily.count == 1)
        #expect(result.sessionsWithUsage == 1)
    }

    @Test func filtersOldUsageAndReportsMissingOnlyWithinRange() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = now.addingTimeInterval(-40 * 86_400)
        let oldSession = SessionRecord(providerID: .claudeCode, updatedAt: old)
        let recentSession = SessionRecord(providerID: .codex, updatedAt: now)
        let result = SessionUsageSummary.summarize(
            [(oldSession, []), (recentSession, [])], range: .sevenDays, now: now
        )
        #expect(result.sessionsMissingUsage == 1)
        #expect(result.totals.requests == 0)
        #expect(result.daily.isEmpty)
    }

    @Test func fallsBackToSessionTotalsWhenTurnsHaveNoUsage() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let session = SessionRecord(
            providerID: .claudeCode,
            updatedAt: now,
            totalUsage: TokenUsage(inputTokens: 7, outputTokens: 3)
        )
        let result = SessionUsageSummary.summarize(
            [(session, [])], range: .all, now: now
        )
        #expect(result.totals.totalTokens == 10)
        #expect(result.totals.requests == 1)
        #expect(result.byAgent.first?.key == "claude-code")
    }
}
