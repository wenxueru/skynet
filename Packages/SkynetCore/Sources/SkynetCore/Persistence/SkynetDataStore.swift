import Foundation

/// Everything SkynetCore persists, as one protocol.
///
/// The macOS and iOS apps point it at the shared **app group container**
/// so projects, sessions, transcripts, provider configurations, pairing,
/// and attachment blobs are available on both devices. Implementations:
/// `JSONDiskStore` (production) and `InMemoryStore` (tests, previews).
///
/// Collections are small enough that read-whole/write-whole is the right
/// trade; only the message log is incremental (append-only JSONL).
public protocol PersistenceStore: Sendable {
    // MARK: Projects

    func loadProjects() throws -> [Project]
    func saveProjects(_ projects: [Project]) throws

    // MARK: User-configured providers
    // (Built-ins are not persisted; merge at load time with ProviderCatalog.)

    func loadUserProviders() throws -> [AgentProviderDescriptor]
    func saveUserProviders(_ providers: [AgentProviderDescriptor]) throws

    // MARK: Sessions

    /// All sessions, newest first. `projectID` filters to one project.
    func loadSessions(matching projectID: ProjectID?) throws -> [SessionRecord]
    /// Inserts or updates one session record.
    func saveSession(_ session: SessionRecord) throws
    func deleteSession(id: SessionID) throws

    // MARK: Messages

    /// Appends to the session's transcript log, creating it on first write.
    func appendMessage(_ message: Message, to session: SessionID) throws
    /// The session transcript in order. Torn trailing lines (crash during
    /// append) are skipped rather than failing the read.
    func loadMessages(for session: SessionID) throws -> [Message]
    /// Atomically replaces a transcript, used when importing provider-owned
    /// history discovered outside Skynet.
    func replaceMessages(_ messages: [Message], for session: SessionID) throws

    // MARK: Relay pairing

    func savePairing(_ pairing: PairingRecord) throws
    func loadPairing() throws -> PairingRecord?
    func deletePairing() throws

    // MARK: Attachment blobs

    func storeBlob(
        _ data: Data,
        mediaType: String,
        fileName: String?
    ) throws -> BlobReference
    func loadBlob(_ reference: BlobReference) throws -> Data

    // MARK: Maintenance

    /// Deletes everything SkynetCore stored. Used by "reset all data" and
    /// tests. Does not touch files SkynetCore does not own.
    func wipeAllData() throws
}

// MARK: - Disk implementation

/// Filesystem-backed `PersistenceStore` for app-group containers.
///
/// Layout under the root (usually `<app-group>/skynet/`):
///
/// ```
/// projects.json                  all projects (one envelope)
/// providers.json                 user-configured providers (one envelope)
/// pairing.json                   relay pairing (one envelope)
/// sessions/<uuid>.json           one session record each
/// sessions/<uuid>.jsonl          append-only transcript, one envelope/line
/// blobs/<xx>/<sha256>            content-addressed attachments
/// ```
public struct JSONDiskStore: PersistenceStore {
    public static let messagePageSize = 256 * 1024

    /// The `skynet` subdirectory the apps should use inside an app-group
    /// container.
    public static func defaultRoot(in container: URL) -> URL {
        container.appendingPathComponent("skynet", isDirectory: true)
    }

    public let rootURL: URL
    public let migrations: [StoreMigration]
    private let blobs: BlobStore

    public init(rootURL: URL, migrations: [StoreMigration] = StoreMigrations.standard) throws {
        self.rootURL = rootURL
        self.migrations = migrations
        try JSONFileIO.ensureDirectory(at: rootURL)
        self.blobs = try BlobStore(
            directory: rootURL.appendingPathComponent("blobs", isDirectory: true)
        )
    }

    // MARK: Paths

    private var projectsURL: URL {
        rootURL.appendingPathComponent("projects.json")
    }
    private var providersURL: URL {
        rootURL.appendingPathComponent("providers.json")
    }
    private var pairingURL: URL {
        rootURL.appendingPathComponent("pairing.json")
    }
    private var sessionsDirectory: URL {
        rootURL.appendingPathComponent("sessions", isDirectory: true)
    }
    private func sessionURL(_ id: SessionID) -> URL {
        sessionsDirectory.appendingPathComponent("\(id.description).json")
    }
    private func transcriptURL(_ id: SessionID) -> URL {
        sessionsDirectory.appendingPathComponent("\(id.description).jsonl")
    }

    // MARK: Read/write plumbing

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONFileIO.write(try StoreEnvelope.wrap(value), to: url)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard let envelope = try JSONFileIO.read(StoreEnvelope.self, from: url) else {
            return nil
        }
        return try envelope.migrated(through: migrations).unwrap(type)
    }

    // MARK: Projects

    public func loadProjects() throws -> [Project] {
        try read([Project].self, from: projectsURL) ?? []
    }

    public func saveProjects(_ projects: [Project]) throws {
        try write(projects, to: projectsURL)
    }

    // MARK: Providers

    public func loadUserProviders() throws -> [AgentProviderDescriptor] {
        try read([AgentProviderDescriptor].self, from: providersURL) ?? []
    }

    public func saveUserProviders(_ providers: [AgentProviderDescriptor]) throws {
        for provider in providers {
            try provider.validate()
        }
        try write(providers, to: providersURL)
    }

    // MARK: Sessions

    public func loadSessions(matching projectID: ProjectID?) throws -> [SessionRecord] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        var sessions: [SessionRecord] = []
        for url in contents where url.pathExtension == "json" {
            if let session = try read(SessionRecord.self, from: url) {
                sessions.append(session)
            }
        }
        if let projectID {
            sessions = sessions.filter { $0.projectID == projectID }
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func saveSession(_ session: SessionRecord) throws {
        try write(session, to: sessionURL(session.id))
    }

    public func deleteSession(id: SessionID) throws {
        try JSONFileIO.remove(at: sessionURL(id))
        try JSONFileIO.remove(at: transcriptURL(id))
    }

    // MARK: Messages

    public func appendMessage(_ message: Message, to session: SessionID) throws {
        let envelope = try StoreEnvelope.wrap(message)
        let data = try JSONFileIO.encoder.encode(envelope)
        try JSONFileIO.appendLine(data, to: transcriptURL(session))
    }

    public func loadMessages(for session: SessionID) throws -> [Message] {
        let lines = try JSONFileIO.readLines(from: transcriptURL(session))
        var messages: [Message] = []
        for line in lines {
            guard
                let message = try? StoreEnvelope.decode(
                    Message.self,
                    from: line,
                    migrations: migrations
                )
            else {
                // Torn or corrupt line (crash mid-append, disk issue):
                // skip it rather than losing the rest of the transcript.
                continue
            }
            messages.append(message)
        }
        return messages
    }

    /// Loads the newest bounded slice of a transcript. `olderCursor` is a byte
    /// offset that can be passed back to load the preceding slice.
    public func loadMessagesPage(
        for session: SessionID,
        before cursor: Int64? = nil,
        byteLimit: Int = JSONDiskStore.messagePageSize
    ) throws -> (messages: [Message], olderCursor: Int64?) {
        let url = transcriptURL(session)
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], nil) }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let end = min(UInt64(max(0, cursor ?? Int64(fileSize))), fileSize)
        guard end > 0 else { return ([], nil) }

        let limit = UInt64(max(1, byteLimit))
        let requestedStart = end > limit ? end - limit : 0
        var start = requestedStart
        if start > 0 {
            try handle.seek(toOffset: start - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) {
                start = try nextLineStart(in: handle, from: start, before: end)
                if start >= end {
                    start = try previousLineStart(in: handle, before: requestedStart)
                }
            }
        }

        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: Int(end - start)) ?? Data()
        let messages = data.split(separator: 0x0A).compactMap { line in
            try? StoreEnvelope.decode(
                Message.self,
                from: Data(line),
                migrations: migrations
            )
        }
        let olderCursor = start > 0 && start < end ? Int64(start) : nil
        return (messages, olderCursor)
    }

    private func nextLineStart(
        in handle: FileHandle,
        from offset: UInt64,
        before end: UInt64
    ) throws -> UInt64 {
        var position = offset
        while position < end {
            try handle.seek(toOffset: position)
            let chunk = try handle.read(upToCount: Int(min(64 * 1024, end - position))) ?? Data()
            guard !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: 0x0A) {
                return position + UInt64(chunk.distance(from: chunk.startIndex, to: newline)) + 1
            }
            position += UInt64(chunk.count)
        }
        return end
    }

    private func previousLineStart(in handle: FileHandle, before offset: UInt64) throws -> UInt64 {
        var upperBound = offset
        while upperBound > 0 {
            let lowerBound = upperBound > 64 * 1024 ? upperBound - 64 * 1024 : 0
            try handle.seek(toOffset: lowerBound)
            let chunk = try handle.read(upToCount: Int(upperBound - lowerBound)) ?? Data()
            if let newline = chunk.lastIndex(of: 0x0A) {
                return lowerBound + UInt64(chunk.distance(from: chunk.startIndex, to: newline)) + 1
            }
            upperBound = lowerBound
        }
        return 0
    }

    public func replaceMessages(_ messages: [Message], for session: SessionID) throws {
        let lines = try messages.map { try JSONFileIO.encoder.encode(StoreEnvelope.wrap($0)) }
        try JSONFileIO.writeLines(lines, to: transcriptURL(session))
    }

    // MARK: Pairing

    public func savePairing(_ pairing: PairingRecord) throws {
        try write(pairing, to: pairingURL)
    }

    public func loadPairing() throws -> PairingRecord? {
        try read(PairingRecord.self, from: pairingURL)
    }

    public func deletePairing() throws {
        try JSONFileIO.remove(at: pairingURL)
    }

    // MARK: Blobs

    public func storeBlob(
        _ data: Data,
        mediaType: String,
        fileName: String?
    ) throws -> BlobReference {
        try blobs.store(data, mediaType: mediaType, fileName: fileName)
    }

    public func loadBlob(_ reference: BlobReference) throws -> Data {
        try blobs.load(reference)
    }

    // MARK: Maintenance

    public func wipeAllData() throws {
        try JSONFileIO.remove(at: rootURL)
        try JSONFileIO.ensureDirectory(at: rootURL)
        // `blobs` is a path wrapper, so recreating its directory is all the
        // re-initialization needed.
        try JSONFileIO.ensureDirectory(at: blobs.directory)
    }
}
