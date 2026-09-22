import Foundation

/// An image the user attached to a prompt. Carries raw bytes plus metadata so
/// the relay can upload it as-is; thumbnails are rendered on demand in the UI.
public struct ImageAttachment: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var fileName: String
    public var mimeType: String
    public var data: Data

    public init(
        id: UUID = UUID(),
        fileName: String,
        mimeType: String = "image/jpeg",
        data: Data
    ) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
        self.data = data
    }

    /// Identity is the attachment ID; payload bytes never affect equality or
    /// hashing so large images stay cheap to diff.
    public static func == (lhs: ImageAttachment, rhs: ImageAttachment) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public var byteCount: Int { data.count }
}

/// Connection state of the relay link to a paired Mac.
public enum ConnectionState: Equatable, Sendable {
    /// No link; `reason` explains what happened for the banner UI.
    case disconnected(reason: String?)
    case connecting
    case connected

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public static let initial = ConnectionState.disconnected(reason: nil)
}
