import Foundation

/// A project living on a paired machine that sessions can be opened against.
public struct Project: Identifiable, Hashable, Codable, Sendable {
    public let id: ProjectID
    public var machineID: MachineID
    public var name: String
    /// Path as shown to the user, e.g. "~/Developer/skynet".
    public var displayPath: String
    public var gitBranch: String?
    public var lastActivityAt: Date?

    public init(
        id: ProjectID,
        machineID: MachineID,
        name: String,
        displayPath: String,
        gitBranch: String? = nil,
        lastActivityAt: Date? = nil
    ) {
        self.id = id
        self.machineID = machineID
        self.name = name
        self.displayPath = displayPath
        self.gitBranch = gitBranch
        self.lastActivityAt = lastActivityAt
    }

    /// Short label for toolbars and list rows, e.g. "skynet · main".
    public var contextLabel: String {
        if let branch = gitBranch, !branch.isEmpty {
            return "\(name) · \(branch)"
        }
        return name
    }
}
