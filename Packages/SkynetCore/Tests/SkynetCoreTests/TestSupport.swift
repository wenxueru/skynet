import Foundation
import SkynetCore
import Testing

/// A self-cleaning temporary directory for disk-store tests.
final class TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("skynet-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Drains an event stream to an array. Returns when the stream finishes.
func collectEvents(
    _ stream: AsyncThrowingStream<AgentEvent, Error>
) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

/// The events of one kind, for order-insensitive assertions.
func events<A: Equatable>(
    _ events: [AgentEvent],
    of kind: @Sendable (AgentEvent) -> A?
) -> [A] {
    events.compactMap { kind($0) }
}

extension AgentEvent {
    var turnCompleted: TurnSummary? {
        if case .turnCompleted(let summary) = self { return summary }
        return nil
    }

    var turnFailed: TurnFailure? {
        if case .turnFailed(let failure) = self { return failure }
        return nil
    }

    var message: Message? {
        if case .messageCompleted(let message) = self { return message }
        return nil
    }

    var sessionToken: String? {
        if case .sessionTokenReceived(let token) = self { return token }
        return nil
    }

    var toolCallStarted: ToolCall? {
        if case .toolCallStarted(let call) = self { return call }
        return nil
    }

    var toolCallCompleted: ToolCallResult? {
        if case .toolCallCompleted(let result) = self { return result }
        return nil
    }

    var permissionRequest: PermissionRequest? {
        if case .permissionRequested(let request) = self { return request }
        return nil
    }

    var usage: TokenUsage? {
        if case .usageReported(let usage) = self { return usage }
        return nil
    }

    var unhandled: JSONValue? {
        if case .unhandledEvent(raw: let raw) = self { return raw }
        return nil
    }
}
