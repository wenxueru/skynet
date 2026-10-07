import Foundation

/// Supplements exec dialects that omit collaboration lifecycle items from
/// stdout. Reads only newly appended records of one explicitly resolved parent
/// rollout, never child logs or transcript contents into the conversation.
public actor CodexSubagentActivityReader {
    public struct Page: Sendable {
        public let reports: [SubagentStatusReport]
        public let hasMore: Bool
        public let isFinished: Bool
    }

    private let handle: FileHandle
    private let parentThreadID: String
    private let notBefore: Date
    private let chunkSize: Int
    private let maximumLineBytes: Int
    private var offset: UInt64
    private var pending = Data()
    private var discardingLine = false
    private var turnID: String?
    private var finished = false

    public init(
        url: URL, parentThreadID: String, notBefore: Date,
        startAtEnd: Bool = true,
        chunkSize: Int = 256 * 1024, maximumLineBytes: Int = 1024 * 1024
    ) throws {
        self.handle = try FileHandle(forReadingFrom: url)
        self.parentThreadID = parentThreadID
        self.notBefore = notBefore
        self.chunkSize = max(1, chunkSize)
        self.maximumLineBytes = max(1, maximumLineBytes)
        offset = startAtEnd ? try handle.seekToEnd() : 0
        // An incomplete line already present at capture time isn't a new event.
        if offset > 0 {
            try handle.seek(toOffset: offset - 1)
            discardingLine = try handle.read(upToCount: 1) != Data([0x0A])
        }
    }

    deinit { try? handle.close() }

    /// Each call has bounded I/O and line memory; callers yield between pages.
    /// The first fresh task_started locks this reader to one provider turn.
    public func readNext() throws -> Page {
        guard !finished else { return .init(reports: [], hasMore: false, isFinished: true) }
        let end = try handle.seekToEnd()
        guard end >= offset else {
            // Truncation must not replay old history as current activity.
            finished = true
            return .init(reports: [], hasMore: false, isFinished: true)
        }
        try handle.seek(toOffset: offset)
        let bytes = try handle.read(upToCount: Int(min(UInt64(chunkSize), end - offset))) ?? Data()
        offset += UInt64(bytes.count)
        var reports: [SubagentStatusReport] = []
        let fragments = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
        for fragment in fragments.enumerated() {
            let endsLine = fragment.offset < fragments.count - 1
            if !discardingLine {
                if pending.count + fragment.element.count > maximumLineBytes {
                    pending.removeAll(keepingCapacity: true)
                    discardingLine = true
                } else {
                    pending.append(contentsOf: fragment.element)
                }
            }
            if endsLine {
                if !discardingLine, let report = consume(pending) { reports.append(report) }
                pending.removeAll(keepingCapacity: true)
                discardingLine = false
                if finished { break }
            }
        }
        return .init(reports: reports, hasMore: !finished && offset < end, isFinished: finished)
    }

    private func consume(_ data: Data) -> SubagentStatusReport? {
        guard let row = try? JSONDecoder().decode(JSONValue.self, from: data),
              row["type"]?.stringValue == "event_msg",
              let payload = row["payload"],
              let id = payload["turn_id"]?.stringValue, !id.isEmpty else { return nil }
        switch payload["type"]?.stringValue {
        case "task_started":
            guard turnID == nil else { return nil }
            if let timestamp = row["timestamp"]?.stringValue {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                guard let started = formatter.date(from: timestamp), started >= notBefore else { return nil }
            } else {
                // Older dialects only have second-rounded task clocks. Normal
                // resumed readers also have the stricter captured EOF boundary.
                guard let seconds = payload["started_at"]?.intValue,
                      Date(timeIntervalSince1970: Double(seconds)) >= notBefore.addingTimeInterval(-1) else { return nil }
            }
            turnID = id
        case "task_complete", "turn_aborted":
            if id == turnID { finished = true }
        case "item_completed":
            guard id == turnID, payload["thread_id"]?.stringValue == parentThreadID,
                  let item = payload["item"] else { return nil }
            return SubagentStatusReport.activity(item)
        default: break
        }
        return nil
    }
}
