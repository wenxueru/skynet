import Foundation
import SkynetCore

struct DiscoverySessionKey: Hashable, Codable {
    let backendID: BackendID?
    let providerID: ProviderID
    let resumeToken: String?

    init(backendID: BackendID?, providerID: ProviderID, resumeToken: String?) {
        self.backendID = backendID
        self.providerID = providerID
        self.resumeToken = resumeToken
    }

    init(session: SessionRecord) {
        self.init(
            backendID: session.backendID,
            providerID: session.providerID,
            resumeToken: session.providerResumeToken
        )
    }
}

/// Imports discovery snapshots into the local registry without owning UI
/// selection, network scanning or transcript loading. Partial writes retain
/// the same ordering and error semantics as the application coordinator.
@MainActor
enum SessionDiscoveryRegistry {
    static func merge(
        _ snapshots: [MachineSessionSnapshot], projects: inout [Project],
        sessions: inout [SessionRecord], deletedKeys: Set<DiscoverySessionKey>,
        selectedSessionID: SessionID?, store: JSONDiskStore
    ) throws {
        var sessionIndexes: [DiscoverySessionKey: Int] = [:]
        for (index, session) in sessions.enumerated() {
            let key = DiscoverySessionKey(session: session)
            if sessionIndexes[key] == nil { sessionIndexes[key] = index }
        }
        for snapshot in snapshots {
            var importedKeys = Set<DiscoverySessionKey>()
            for discovered in snapshot.sessions.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                let key = DiscoverySessionKey(
                    backendID: snapshot.machine.id,
                    providerID: discovered.providerID,
                    resumeToken: discovered.providerSessionID
                )
                guard importedKeys.insert(key).inserted,
                      !deletedKeys.contains(key) else { continue }
                let project = project(
                    for: discovered.workingDirectory,
                    backendID: snapshot.machine.id, projects: &projects
                )
                let existingIndex = sessionIndexes[key]
                var record = existingIndex.map { sessions[$0] } ?? SessionRecord(
                    projectID: project.id,
                    providerID: discovered.providerID,
                    modelID: discovered.modelID,
                    title: discovered.title,
                    backendID: snapshot.machine.id,
                    workingDirectory: discovered.workingDirectory,
                    createdAt: discovered.createdAt,
                    updatedAt: discovered.updatedAt,
                    providerResumeToken: discovered.providerSessionID
                )
                let previousUpdatedAt = record.updatedAt
                let previousMessageCount = record.messageCount
                record.projectID = project.id
                record.modelID = record.modelID ?? discovered.modelID
                record.backendID = snapshot.machine.id
                record.workingDirectory = discovered.workingDirectory
                record.providerResumeToken = discovered.providerSessionID
                record.updatedAt = max(record.updatedAt, discovered.updatedAt)
                if discovered.totalUsage.totalTokens != nil {
                    record.totalUsage = discovered.totalUsage
                }
                if record.title == nil { record.title = discovered.title }
                let isRemote = snapshot.machine.id != DiscoveredMachine.local.id
                let discoveredMessageCount = discovered.messages.count
                let hasMoreMessages = discoveredMessageCount > previousMessageCount
                let hasNewerLocalMessages = !isRemote
                    && discoveredMessageCount == previousMessageCount
                    && previousUpdatedAt < discovered.updatedAt
                let shouldReplaceMessages = existingIndex == nil || hasMoreMessages || hasNewerLocalMessages
                if existingIndex != nil,
                   selectedSessionID != record.id,
                   hasMoreMessages,
                   discovered.messages.dropFirst(previousMessageCount).contains(where: {
                       $0.origin == .agent && !$0.plainText.isEmpty
                   }) {
                    record.markedUnreadAt = discovered.updatedAt
                }
                var needsImageUpgrade = false
                if !shouldReplaceMessages,
                   discovered.messages.contains(where: Self.containsImage) {
                    needsImageUpgrade = !(try store.loadMessages(for: record.id))
                        .contains(where: Self.containsImage)
                }
                if !discovered.messages.isEmpty, shouldReplaceMessages || needsImageUpgrade {
                    record.messageCount = discoveredMessageCount
                    let messages = try SessionTranscriptController.persistableMessages(discovered.messages, store: store)
                    try store.replaceMessages(messages, for: record.id)
                }
                try store.saveSession(record)
                if let existingIndex {
                    sessions[existingIndex] = record
                } else {
                    sessions.append(record)
                    sessionIndexes[key] = sessions.endIndex - 1
                }
            }
        }
        try store.saveProjects(projects)
        sessions.sort { $0.updatedAt > $1.updatedAt }
    }

    private static func containsImage(_ message: Message) -> Bool {
        message.content.contains { if case .image = $0 { true } else { false } }
    }

    private static func project(for rootPath: String?, backendID: BackendID, projects: inout [Project]) -> Project {
        if let existing = projects.first(where: {
            $0.rootPath == rootPath && BackendID($0.metadata["backendID"] ?? "local") == backendID
        }) {
            return existing
        }
        let name = rootPath.map {
            let component = URL(fileURLWithPath: $0).lastPathComponent
            return component.isEmpty ? $0 : component
        } ?? "Conversations"
        let project = Project(
            name: name,
            rootPath: rootPath,
            metadata: ["backendID": backendID.rawValue, "discovered": "true"]
        )
        projects.append(project)
        return project
    }
}
