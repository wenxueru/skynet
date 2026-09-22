import CryptoKit
import Foundation

/// Content-addressed storage for binary attachments (images).
///
/// Content is keyed by SHA-256: storing the same bytes twice costs nothing,
/// and a `BlobReference` is self-verifying in size. Blobs live two levels
/// deep (`blobs/ab/abcd…`) to keep directories small.
///
/// This layout is safe for app-group containers: both apps share the same
/// blobs, and a blob referenced by a synced message is present on every
/// device that synced the store.
public struct BlobStore: Sendable {
    public let directory: URL

    /// Creates (or opens) a blob store rooted at `directory`.
    public init(directory: URL) throws {
        self.directory = directory
        try JSONFileIO.ensureDirectory(at: directory)
    }

    /// Stores bytes and returns their reference.
    public func store(
        _ data: Data,
        mediaType: String,
        fileName: String? = nil
    ) throws -> BlobReference {
        let digest = SHA256.hash(data: data)
        let blobID = digest.map { String(format: "%02x", $0) }.joined()
        let target = path(for: blobID)
        if !FileManager.default.fileExists(atPath: target.path) {
            do {
                try JSONFileIO.ensureDirectory(
                    at: target.deletingLastPathComponent()
                )
                try data.write(to: target, options: .atomic)
            } catch {
                throw SkynetError.persistenceFailure(
                    underlying: "Cannot write blob \(blobID): \(error.localizedDescription)"
                )
            }
        }
        return BlobReference(
            blobID: blobID,
            byteCount: data.count,
            mediaType: mediaType,
            fileName: fileName
        )
    }

    /// Loads the bytes a reference points at, verifying the recorded size.
    public func load(_ reference: BlobReference) throws -> Data {
        let url = path(for: reference.blobID)
        guard let data = try? Data(contentsOf: url) else {
            throw SkynetError.notFound(what: "Blob", id: reference.blobID)
        }
        guard data.count == reference.byteCount else {
            throw SkynetError.persistenceFailure(
                underlying:
                    "Blob \(reference.blobID) has \(data.count) bytes on disk but its reference claims \(reference.byteCount)."
            )
        }
        return data
    }

    public func exists(_ blobID: String) -> Bool {
        FileManager.default.fileExists(atPath: path(for: blobID).path)
    }

    public func path(for blobID: String) -> URL {
        let prefix = String(blobID.prefix(2))
        return directory
            .appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent(blobID, isDirectory: false)
    }
}
