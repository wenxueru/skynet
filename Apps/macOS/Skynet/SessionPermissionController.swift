import Foundation
import Observation
import SkynetCore

/// Owns one pending approval and its continuation. Turn cancellation stays
/// with AppModel; only the exact captured approval generation may be answered.
@MainActor
@Observable
final class SessionPermissionController {
    private(set) var pendingPermissionRequest: PermissionRequest?
    private(set) var pendingPermissionSessionTitle: String?
    private(set) var pendingPermissionSessionID: SessionID?
    private(set) var permissionRequestToken: UUID?
    @ObservationIgnored private var permissionContinuation: CheckedContinuation<PermissionResponse, Never>?
    var hasPendingContinuation: Bool { permissionContinuation != nil }

    func answerPermission(_ decision: PermissionResponse.Decision) {
        guard let request = pendingPermissionRequest else { return }
        permissionContinuation?.resume(
            returning: PermissionResponse(requestID: request.id, decision: decision)
        )
        permissionContinuation = nil
        pendingPermissionRequest = nil
        pendingPermissionSessionTitle = nil
        pendingPermissionSessionID = nil
        permissionRequestToken = nil
    }

    func request(
        _ request: PermissionRequest, sessionID: SessionID, sessionTitle: String? = nil
    ) async -> PermissionResponse {
        guard !Task.isCancelled else {
            return PermissionResponse(requestID: request.id, decision: .deny,
                                      reason: "The permission request was cancelled.")
        }
        if let pendingPermissionRequest {
            permissionContinuation?.resume(
                returning: PermissionResponse(
                    requestID: pendingPermissionRequest.id,
                    decision: .deny,
                    reason: "A newer permission request replaced this request."
                )
            )
        }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingPermissionRequest = request
                pendingPermissionSessionTitle = sessionTitle
                pendingPermissionSessionID = sessionID
                permissionRequestToken = token
                permissionContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                // Providers can reuse request IDs. Only this exact installed
                // continuation may be denied by its cancellation callback.
                guard let self, self.permissionRequestToken == token else { return }
                self.answerPermission(.deny)
            }
        }
    }
}
