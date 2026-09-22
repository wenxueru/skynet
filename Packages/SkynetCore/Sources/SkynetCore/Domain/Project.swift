import Foundation

/// A user workspace: a name plus (usually) a directory the agent works in.
///
/// `rootPath` is a path *on the backend's filesystem*. When the session runs
/// over SSH or a relay, it is a path on the Mac — SkynetCore never assumes
/// it exists locally.
public struct Project: Codable, Hashable, Sendable, Identifiable {
    public var id: ProjectID
    public var name: String
    /// Absolute directory path on the backend. `nil` for projects that are
    /// pure conversation spaces with no working directory.
    public var rootPath: String?
    public var defaultProviderID: ProviderID?
    public var defaultModelID: ModelID?
    public var createdAt: Date
    public var updatedAt: Date
    /// Free-form, UI-owned metadata. Keys are stable across syncs, so treat
    /// them as semi-public identifiers.
    public var metadata: [String: String]

    public init(
        id: ProjectID = ProjectID(),
        name: String,
        rootPath: String? = nil,
        defaultProviderID: ProviderID? = nil,
        defaultModelID: ModelID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.defaultProviderID = defaultProviderID
        self.defaultModelID = defaultModelID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}
