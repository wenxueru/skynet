import Foundation

public enum SessionUsageRange: String, CaseIterable, Sendable {
    case sevenDays
    case thirtyDays
    case all

    public var title: String {
        switch self {
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .all: "All time"
        }
    }

    fileprivate func contains(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        switch self {
        case .all: true
        case .sevenDays: date >= (calendar.date(byAdding: .day, value: -7, to: now) ?? now)
        case .thirtyDays: date >= (calendar.date(byAdding: .day, value: -30, to: now) ?? now)
        }
    }
}

public struct UsageBucket: Sendable, Identifiable {
    public let key: String
    public var usage: TokenUsage
    public var requests: Int

    public var id: String { key }
    public var totalTokens: Int { usage.totalTokens ?? 0 }

    public init(key: String, usage: TokenUsage = TokenUsage(), requests: Int = 0) {
        self.key = key
        self.usage = usage
        self.requests = requests
    }
}

public struct SessionUsageSummary: Sendable {
    public let totals: UsageBucket
    public let daily: [UsageBucket]
    public let byAgent: [UsageBucket]
    public let byModel: [UsageBucket]
    public let sessionsWithUsage: Int
    public let sessionsMissingUsage: Int

    public static func summarize(
        _ records: [(session: SessionRecord, messages: [Message])],
        range: SessionUsageRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> SessionUsageSummary {
        var totals = UsageBucket(key: "Total")
        var daily: [String: UsageBucket] = [:]
        var agents: [String: UsageBucket] = [:]
        var models: [String: UsageBucket] = [:]
        var withUsage = 0
        var missingUsage = 0

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        func addToBucket(_ key: String, usage: TokenUsage, buckets: inout [String: UsageBucket]) {
            var bucket = buckets[key] ?? UsageBucket(key: key)
            bucket.usage += usage
            bucket.requests += 1
            buckets[key] = bucket
        }

        func add(_ usage: TokenUsage, at date: Date, agent: String, model: String) {
            guard range.contains(date, now: now, calendar: calendar) else { return }
            let day = formatter.string(from: date)
            totals.usage += usage
            totals.requests += 1
            addToBucket(day, usage: usage, buckets: &daily)
            addToBucket(agent, usage: usage, buckets: &agents)
            addToBucket(model, usage: usage, buckets: &models)
        }

        for record in records {
            let agent = record.session.providerID.rawValue
            let reported = record.messages.compactMap { message -> (Date, String, TokenUsage)? in
                guard message.origin == .agent, let usage = message.usage,
                      usage.totalTokens != nil else { return nil }
                return (message.createdAt,
                        message.modelID?.rawValue ?? record.session.modelID?.rawValue ?? "Unknown model",
                        usage)
            }
            if !reported.isEmpty {
                withUsage += 1
                for (date, model, usage) in reported {
                    add(usage, at: date, agent: agent, model: model)
                }
            } else if record.session.totalUsage.totalTokens != nil {
                withUsage += 1
                add(record.session.totalUsage,
                    at: record.session.updatedAt,
                    agent: agent,
                    model: record.session.modelID?.rawValue ?? "Unknown model")
            } else if range.contains(record.session.updatedAt, now: now, calendar: calendar) {
                missingUsage += 1
            }
        }

        let ranked: ([String: UsageBucket]) -> [UsageBucket] = { values in
            values.values.sorted {
                if $0.totalTokens == $1.totalTokens { return $0.key < $1.key }
                return $0.totalTokens > $1.totalTokens
            }
        }
        return SessionUsageSummary(
            totals: totals,
            daily: daily.values.sorted { $0.key < $1.key },
            byAgent: ranked(agents),
            byModel: ranked(models),
            sessionsWithUsage: withUsage,
            sessionsMissingUsage: missingUsage
        )
    }
}
