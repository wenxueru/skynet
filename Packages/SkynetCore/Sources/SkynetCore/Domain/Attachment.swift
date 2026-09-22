import Foundation

/// A reference to binary content stored in the content-addressed blob store.
///
/// The blob itself lives under `<container>/skynet/blobs/` (or an equivalent
/// in-memory location in tests) and is addressed by its SHA-256 digest, so
/// identical attachments are stored once and deduplicated for free.
public struct BlobReference: Codable, Hashable, Sendable {
    /// SHA-256 hex digest of the content (64 lowercase hex characters).
    public var blobID: String
    public var byteCount: Int
    /// e.g. `image/png`.
    public var mediaType: String
    public var fileName: String?

    public init(blobID: String, byteCount: Int, mediaType: String, fileName: String? = nil) {
        self.blobID = blobID
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.fileName = fileName
    }
}

/// An image attached to a user turn.
///
/// Two payload shapes exist because the two consumers want different things:
/// the agent CLI wants bytes *now* (inline), while persistence wants to keep
/// the JSON small (blob reference). `AgentSession` normalizes attachments to
/// blob references when persisting and sends inline data to the provider.
public struct ImageAttachment: Codable, Hashable, Sendable, Identifiable {
    public enum Payload: Codable, Hashable, Sendable {
        /// Raw image bytes carried with the attachment.
        case inline(data: Data, mediaType: String)
        /// Content addressed in the blob store.
        case blob(BlobReference)
    }

    public var id: UUID
    public var payload: Payload
    public var fileName: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init(
        id: UUID = UUID(),
        payload: Payload,
        fileName: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.id = id
        self.payload = payload
        self.fileName = fileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Convenience constructor for the common inline case.
    public init(
        data: Data,
        mediaType: String,
        fileName: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.init(
            id: UUID(),
            payload: .inline(data: data, mediaType: mediaType),
            fileName: fileName,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    /// The media type regardless of payload shape.
    public var mediaType: String {
        switch payload {
        case .inline(_, let mediaType): return mediaType
        case .blob(let reference): return reference.mediaType
        }
    }
}
