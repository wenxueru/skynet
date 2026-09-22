import Foundation

/// Central registry of accessibility identifiers used by UI tests and
/// preview automation. Views reference these constants instead of scattering
/// string literals, so renaming an element is a compile-time change.
///
/// Per-element identifiers (rows, tool calls, …) are built with the static
/// builder functions in each namespace.
public enum A11yID {
    // MARK: - Pairing

    public enum Pairing {
        public static let root = "pairing.root"
        public static let scanQRButton = "pairing.scan-qr-button"
        public static let enterCodeButton = "pairing.enter-code-button"
        public static let manualEntryField = "pairing.manual-entry-field"
        public static let manualEntrySubmit = "pairing.manual-entry-submit"
        public static let machineNameLabel = "pairing.machine-name-label"
        public static let verificationField = "pairing.verification-field"
        public static let verifyButton = "pairing.verify-button"
        public static let cancelButton = "pairing.cancel-button"
        public static let successLabel = "pairing.success-label"
        public static let successDoneButton = "pairing.success-done-button"
        public static let errorLabel = "pairing.error-label"
        public static let scannerView = "pairing.scanner-view"
    }

    // MARK: - Library / navigation

    public enum Library {
        public static let root = "library.root"
        public static let pairButton = "library.pair-button"
        public static let emptyPairButton = "library.empty-pair-button"

        public static func machineRow(_ machineID: MachineID) -> String {
            "library.machine-row-\(machineID.rawValue)"
        }

        public static func projectRow(_ projectID: ProjectID) -> String {
            "library.project-row-\(projectID.rawValue)"
        }

        public static func unpairAction(_ machineID: MachineID) -> String {
            "library.unpair-\(machineID.rawValue)"
        }
    }

    // MARK: - Session list

    public enum SessionList {
        public static let root = "session-list.root"
        public static let searchField = "session-list.search-field"
        public static let newSessionButton = "session-list.new-session-button"
        public static let emptyNewSessionButton = "session-list.empty-new-session-button"

        public static func row(_ sessionID: SessionID) -> String {
            "session-list.row-\(sessionID.rawValue)"
        }

        public static func renameAction(_ sessionID: SessionID) -> String {
            "session-list.rename-\(sessionID.rawValue)"
        }
    }

    // MARK: - Session / transcript

    public enum Session {
        public static let root = "session.root"
        public static let title = "session.title"
        public static let menuButton = "session.menu-button"
        public static let renameButton = "session.rename-button"
        public static let settingsButton = "session.settings-button"
        public static let transcript = "session.transcript"
        public static let searchField = "session.search-field"
        public static let searchResultCount = "session.search-result-count"
        public static let searchClearButton = "session.search-clear-button"
        public static let jumpToBottomButton = "session.jump-to-bottom-button"
        public static let cancelTurnButton = "session.cancel-turn-button"
        public static let emptyState = "session.empty-state"

        public static func row(_ itemID: TranscriptItemID) -> String {
            "session.transcript-row-\(itemID.rawValue)"
        }

        public static func toolCallToggle(_ itemID: TranscriptItemID) -> String {
            "session.toolcall-toggle-\(itemID.rawValue)"
        }

        public static func toolCallOutput(_ itemID: TranscriptItemID) -> String {
            "session.toolcall-output-\(itemID.rawValue)"
        }

        public static func messageShowMore(_ itemID: TranscriptItemID) -> String {
            "session.message-more-\(itemID.rawValue)"
        }

        public static func permissionCard(_ itemID: TranscriptItemID) -> String {
            "session.permission-card-\(itemID.rawValue)"
        }

        public static func permissionApprove(_ itemID: TranscriptItemID) -> String {
            "session.permission-approve-\(itemID.rawValue)"
        }

        public static func permissionApproveAlways(_ itemID: TranscriptItemID) -> String {
            "session.permission-always-\(itemID.rawValue)"
        }

        public static func permissionDeny(_ itemID: TranscriptItemID) -> String {
            "session.permission-deny-\(itemID.rawValue)"
        }
    }

    // MARK: - Composer

    public enum Composer {
        public static let root = "composer.root"
        public static let textField = "composer.text-field"
        public static let sendButton = "composer.send-button"
        public static let queueIndicator = "composer.queue-indicator"
        public static let attachPhotoButton = "composer.attach-photo-button"
        public static let attachCameraButton = "composer.attach-camera-button"
        public static let attachmentStrip = "composer.attachment-strip"

        public static func attachment(_ attachmentID: UUID) -> String {
            "composer.attachment-\(attachmentID.uuidString)"
        }

        public static func attachmentRemove(_ attachmentID: UUID) -> String {
            "composer.attachment-remove-\(attachmentID.uuidString)"
        }

        public static let modelButton = "composer.model-button"
        public static let effortButton = "composer.effort-button"
        public static let permissionButton = "composer.permission-button"
        public static let queuedBar = "composer.queued-bar"
        public static let queuedCount = "composer.queued-count"
        public static let queuedListButton = "composer.queued-list-button"
        public static let queuedSheet = "composer.queued-sheet"

        public static func queuedRow(_ promptID: UUID) -> String {
            "composer.queued-row-\(promptID.uuidString)"
        }

        public static func queuedRemove(_ promptID: UUID) -> String {
            "composer.queued-remove-\(promptID.uuidString)"
        }

        public static func queuedRowSendNow(_ promptID: UUID) -> String {
            "composer.queued-send-now-\(promptID.uuidString)"
        }
    }

    // MARK: - Settings

    public enum Settings {
        public static let sheet = "settings.sheet"
        public static let modelPicker = "settings.model-picker"
        public static let effortPicker = "settings.effort-picker"
        public static let permissionPicker = "settings.permission-picker"
        public static let doneButton = "settings.done-button"
    }

    // MARK: - Connectivity

    public enum Connectivity {
        public static let banner = "connection.banner"
        public static let retryButton = "connection.retry-button"
    }
}
