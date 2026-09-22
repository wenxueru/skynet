import Foundation
import SkynetCore

/// A `Notifier` that records every notification instead of presenting it.
public final class RecordingNotifier: Notifier, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SkynetNotification] = []

    public init() {}

    public var notifications: [SkynetNotification] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    public var triggers: [SkynetNotification.Trigger] {
        notifications.map(\.trigger)
    }

    public func notify(_ notification: SkynetNotification) async {
        lock.lock()
        recorded.append(notification)
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        recorded = []
        lock.unlock()
    }
}

/// A `PermissionResponder` with scripted answers.
///
/// When the answer queue is empty, `defaultResponse` (deny) is used, so a
/// test that forgets to script an answer fails safely instead of hanging.
public final class ScriptedPermissionResponder: PermissionResponder, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [PermissionRequest] = []
    private var answerQueue: [PermissionResponse]
    private let fallback: PermissionResponse

    public init(
        responses: [PermissionResponse] = [],
        fallback: PermissionResponse? = nil
    ) {
        self.answerQueue = responses
        self.fallback =
            fallback
            ?? PermissionResponse(requestID: "", decision: .deny, reason: "No scripted answer")
    }

    /// Every ask the responder saw, in order.
    public var requests: [PermissionRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    public func enqueue(_ response: PermissionResponse) {
        lock.lock()
        answerQueue.append(response)
        lock.unlock()
    }

    public func decide(_ request: PermissionRequest) async -> PermissionResponse {
        lock.lock()
        recordedRequests.append(request)
        let answer = answerQueue.isEmpty ? fallback : answerQueue.removeFirst()
        lock.unlock()
        var response = answer
        if response.requestID.isEmpty {
            response.requestID = request.id
        }
        return response
    }
}
