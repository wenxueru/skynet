import Foundation
import SkynetCore

/// A `PersistenceStore` where every operation fails — for exercising
/// persistence-error paths (failed user-message writes, broken stores).
public final class FailingPersistenceStore: PersistenceStore, @unchecked Sendable {
    public init() {}

    private func boom() throws -> Never {
        throw SkynetError.persistenceFailure(underlying: "failing store")
    }

    public func loadProjects() throws -> [Project] { try boom() }
    public func saveProjects(_ projects: [Project]) throws { try boom() }
    public func loadUserProviders() throws -> [AgentProviderDescriptor] { try boom() }
    public func saveUserProviders(_ providers: [AgentProviderDescriptor]) throws { try boom() }
    public func loadSessions(matching projectID: ProjectID?) throws -> [SessionRecord] { try boom() }
    public func saveSession(_ session: SessionRecord) throws { try boom() }
    public func deleteSession(id: SessionID) throws { try boom() }
    public func appendMessage(_ message: Message, to session: SessionID) throws { try boom() }
    public func loadMessages(for session: SessionID) throws -> [Message] { try boom() }
    public func savePairing(_ pairing: PairingRecord) throws { try boom() }
    public func loadPairing() throws -> PairingRecord? { try boom() }
    public func deletePairing() throws { try boom() }
    public func storeBlob(_ data: Data, mediaType: String, fileName: String?) throws -> BlobReference {
        try boom()
    }
    public func loadBlob(_ reference: BlobReference) throws -> Data { try boom() }
    public func wipeAllData() throws { try boom() }
}

/// A `PersistenceStore` backed by dictionaries — fast, disk-free, and
/// inspectable from tests and SwiftUI previews.
///
/// Mirrors `JSONDiskStore` behavior (including provider validation on
/// save) so a test against this double says something about the real store.
public final class InMemoryStore: PersistenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var projects: [Project] = []
    private var userProviders: [AgentProviderDescriptor] = []
    private var sessions: [SessionRecord] = []
    private var transcripts: [SessionID: [Message]] = [:]
    private var pairing: PairingRecord?
    private var blobs: [String: Data] = [:]

    public init() {}

    // MARK: Projects

    public func loadProjects() throws -> [Project] {
        lock.lock()
        defer { lock.unlock() }
        return projects
    }

    public func saveProjects(_ projects: [Project]) throws {
        lock.lock()
        self.projects = projects
        lock.unlock()
    }

    // MARK: Providers

    public func loadUserProviders() throws -> [AgentProviderDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return userProviders
    }

    public func saveUserProviders(_ providers: [AgentProviderDescriptor]) throws {
        for provider in providers {
            try provider.validate()
        }
        lock.lock()
        userProviders = providers
        lock.unlock()
    }

    // MARK: Sessions

    public func loadSessions(matching projectID: ProjectID?) throws -> [SessionRecord] {
        lock.lock()
        defer { lock.unlock() }
        var result = sessions
        if let projectID {
            result = result.filter { $0.projectID == projectID }
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func saveSession(_ session: SessionRecord) throws {
        lock.lock()
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        lock.unlock()
    }

    public func deleteSession(id: SessionID) throws {
        lock.lock()
        sessions.removeAll { $0.id == id }
        transcripts[id] = nil
        lock.unlock()
    }

    // MARK: Messages

    public func appendMessage(_ message: Message, to session: SessionID) throws {
        lock.lock()
        transcripts[session, default: []].append(message)
        lock.unlock()
    }

    public func loadMessages(for session: SessionID) throws -> [Message] {
        lock.lock()
        defer { lock.unlock() }
        return transcripts[session] ?? []
    }

    // MARK: Pairing

    public func savePairing(_ pairing: PairingRecord) throws {
        lock.lock()
        self.pairing = pairing
        lock.unlock()
    }

    public func loadPairing() throws -> PairingRecord? {
        lock.lock()
        defer { lock.unlock() }
        return pairing
    }

    public func deletePairing() throws {
        lock.lock()
        pairing = nil
        lock.unlock()
    }

    // MARK: Blobs

    public func storeBlob(
        _ data: Data,
        mediaType: String,
        fileName: String?
    ) throws -> BlobReference {
        let blobID = data.map { String(format: "%02x", $0) }.joined()
        lock.lock()
        blobs[blobID] = data
        lock.unlock()
        return BlobReference(
            blobID: blobID,
            byteCount: data.count,
            mediaType: mediaType,
            fileName: fileName
        )
    }

    public func loadBlob(_ reference: BlobReference) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let data = blobs[reference.blobID] else {
            throw SkynetError.notFound(what: "Blob", id: reference.blobID)
        }
        return data
    }

    // MARK: Maintenance

    public func wipeAllData() throws {
        lock.lock()
        projects = []
        userProviders = []
        sessions = []
        transcripts = [:]
        pairing = nil
        blobs = [:]
        lock.unlock()
    }
}
