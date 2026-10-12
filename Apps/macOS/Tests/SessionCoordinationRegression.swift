import Foundation
import SkynetCore

// Only external discovery/probe sources are scripted; both controllers are real.
@MainActor
enum SessionTranscriptDiscovery {
    static var page: SessionTranscriptPage?
    static var delay: Duration = .zero
    static var calls = 0

    static func transcriptPage(for record: SessionRecord, before: Int64? = nil) async throws -> SessionTranscriptPage? {
        calls += 1
        let captured = page
        // Intentionally ignores cancellation, exercising the generation guard.
        try? await Task.sleep(for: delay)
        return captured
    }
}

private actor ProbeSource {
    var status: NetworkConnectivityMonitor.Status = .reachable
    var calls = 0
    var delay: Duration = .zero

    func set(_ status: NetworkConnectivityMonitor.Status, delay: Duration = .zero) {
        self.status = status
        self.delay = delay
    }
    func check(_ alias: String) async -> NetworkConnectivityMonitor.Status {
        calls += 1
        let result = status
        try? await Task.sleep(for: delay)
        return result
    }
}

@main
enum SessionCoordinationRegression {
    @MainActor
    static func main() async throws {
        try await history()
        try await connectivity()
        try registry()
        try library()
    }

    @MainActor
    static func history() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skynet-coordination-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JSONDiskStore(rootURL: root)
        let record = SessionRecord(projectID: ProjectID(), providerID: .codex)
        var records = [record.id: record]
        var failure: String?
        let hooks = SessionTranscriptController.Hooks(
            record: { records[$0] }, save: { records[$0.id] = $0 }, reportError: { failure = $0 }
        )
        let unavailable = SessionTranscriptController(store: nil)
        unavailable.load(for: record.id, record: nil, preservePagination: false, hooks: hooks)
        try require(!unavailable.isLoadingTranscript && failure == SkynetError.persistenceFailure(
            underlying: "The application data directory is unavailable."
        ).localizedDescription, "missing store reports the same error without remaining busy")
        failure = nil
        let rows = (0..<180).map { index in
            Message(origin: .user, content: [.text("\(index):" + String(repeating: "x", count: 4096))],
                    createdAt: Date(timeIntervalSince1970: Double(index)))
        }
        for row in rows { try store.appendMessage(row, to: record.id) }
        let controller = SessionTranscriptController(store: store)
        controller.selectedSessionID = record.id
        controller.load(for: record.id, record: nil, preservePagination: false, hooks: hooks)
        try await eventually("cache-first paged load") { !controller.isLoadingTranscript && !controller.messages.isEmpty }
        try require(controller.messages.count < rows.count && controller.canLoadOlderTranscript, "bounded cache page")
        let count = controller.messages.count
        await controller.loadOlderTranscript(hooks: hooks)
        try require(controller.messages.count > count && failure == nil, "older page contributes messages")
        let pageCount = controller.messages.count
        controller.load(for: record.id, record: nil, preservePagination: true, hooks: hooks)
        try await Task.sleep(for: .milliseconds(50))
        try require(controller.messages.count == pageCount, "refresh preserves loaded pages")
        while controller.canLoadOlderTranscript { await controller.loadOlderTranscript(hooks: hooks) }
        try require(controller.messages.map(\.id) == rows.map(\.id), "complete chronological cache pagination")

        let imported = Message(origin: .agent, content: [.text("new provider reply")])
        SessionTranscriptDiscovery.page = SessionTranscriptPage(session: DiscoveredSession(
            providerID: .codex, providerSessionID: "test", title: "QA", workingDirectory: nil,
            modelID: nil, createdAt: record.createdAt, updatedAt: imported.createdAt, messages: [imported]
        ), olderCursor: nil)
        SessionTranscriptDiscovery.delay = .milliseconds(150)
        controller.load(for: record.id, record: record, preservePagination: true, hooks: hooks)
        try await eventually("provider refresh begins") { SessionTranscriptDiscovery.calls > 0 }
        controller.clear()
        controller.selectedSessionID = SessionID()
        try await Task.sleep(for: .milliseconds(200))
        try require(controller.messages.isEmpty, "stale provider completion cannot overwrite new selection")
        SessionTranscriptDiscovery.delay = .zero
        controller.selectedSessionID = record.id
        controller.load(for: record.id, record: record, preservePagination: false, hooks: hooks)
        try await eventually("provider refresh updates cache") { controller.messages.contains { $0.id == imported.id } }
        try require(try store.loadMessages(for: record.id).contains { $0.id == imported.id }, "provider reply persisted")
        print("PASS: history cache, pagination, refresh and selection generation")
    }

    @MainActor
    static func connectivity() async throws {
        let source = ProbeSource()
        let monitor = NetworkConnectivityMonitor(monitorNetwork: false, interval: .milliseconds(20)) {
            await source.check($0)
        }
        let host = DiscoveredMachine(id: BackendID("ssh:fixture"), name: "Fixture", sshAlias: "fixture")
        monitor.configure(machines: [.local, host])
        try require(monitor.hosts[host.id] == .checking, "initial remote state is unknown, not green")
        try await eventually("initial SSH probe") { monitor.hosts[host.id] == .reachable }
        monitor.configure(machines: [host, .local])
        try require(monitor.hosts[host.id] == .reachable, "unchanged targets preserve known status")
        let other = DiscoveredMachine(id: BackendID("ssh:other"), name: "Other", sshAlias: "other")
        monitor.configure(machines: [.local, host, other])
        try require(monitor.hosts[host.id] == .reachable && monitor.hosts[other.id] == .checking,
                    "new targets do not reset unchanged hosts")
        let renamed = DiscoveredMachine(id: other.id, name: "Other", sshAlias: "replacement")
        monitor.configure(machines: [.local, host, renamed])
        try require(monitor.hosts[renamed.id] == .checking, "changed aliases reset to unknown")
        monitor.configure(machines: [.local, host])
        try require(monitor.hosts[other.id] == nil && monitor.hosts[host.id] == .reachable,
                    "removed targets disappear without resetting retained hosts")
        await source.set(.unavailable("Connection refused"))
        try await eventually("continuous SSH disconnect detection") { monitor.hosts[host.id]?.failure != nil }
        await source.set(.reachable)
        try await eventually("continuous SSH recovery") { monitor.hosts[host.id] == .reachable }
        await source.set(.reachable, delay: .milliseconds(100))
        let calls = await source.calls
        try await eventually("in-flight probe") { await source.calls > calls }
        monitor.updateNetwork(available: false)
        try await Task.sleep(for: .milliseconds(150))
        try require(monitor.hosts[host.id]?.failure == "Network unavailable.", "offline state rejects stale success")
        let offlineCalls = await source.calls
        try await Task.sleep(for: .milliseconds(60))
        try require(await source.calls == offlineCalls, "offline network stops SSH launches")
        await source.set(.reachable)
        monitor.updateNetwork(available: true)
        try await eventually("network recovery triggers immediate probe") { monitor.hosts[host.id] == .reachable }
        monitor.configure(machines: [.local])
        try require(monitor.hosts.isEmpty, "disabled/removed hosts stop monitoring")

        let backend = ScriptedExecutionBackend(scripts: [
            .init(stderrLines: ["** WARNING: connection is not using a post-quantum key exchange algorithm."]),
            .init(exitCode: 255, stderrLines: ["Connection refused"])
        ])
        try require(await SSHConnectivityProbe.check("fixture", launcher: backend) == .reachable,
                    "successful SSH warning is not failure")
        let failed = await SSHConnectivityProbe.check("fixture", launcher: backend)
        try require(failed.failure?.contains("Connection refused") == true, "SSH actionable error retained")
        let request = backend.launchedRequests[0]
        try require(request.stdinMode == .closed && request.arguments.contains("-oConnectTimeout=5")
                    && request.arguments.suffix(3) == ["--", "fixture", "true"], "bounded read-only SSH request")
        print("PASS: continuous connectivity, offline/recovery, stale results, host removal and SSH diagnostics")
    }

    @MainActor
    static func registry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skynet-registry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JSONDiskStore(rootURL: root)
        var projects: [Project] = []
        var sessions: [SessionRecord] = []
        let original = Message(origin: .user, content: [.text("original")])
        var discovered = DiscoveredSession(
            providerID: .codex, providerSessionID: "synthetic-registry-thread", title: "Synthetic",
            workingDirectory: "/synthetic/workspace", modelID: nil,
            createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100),
            messages: [original]
        )
        func snapshot(_ machine: DiscoveredMachine, _ rows: [DiscoveredSession]) -> MachineSessionSnapshot {
            .init(machine: machine, sessions: rows, error: nil)
        }
        try SessionDiscoveryRegistry.merge([snapshot(.local, [discovered, discovered])],
            projects: &projects, sessions: &sessions, deletedKeys: [], selectedSessionID: nil, store: store)
        try require(projects.count == 1 && sessions.count == 1, "duplicate discovery keys import once")
        let id = sessions[0].id
        let projectID = projects[0].id
        sessions[0].title = "User title"
        sessions[0].pinMode = .global
        let replacement = Message(origin: .agent, content: [.text("same-count rewrite")])
        discovered.messages = [replacement]
        discovered.updatedAt = Date(timeIntervalSince1970: 200)
        try SessionDiscoveryRegistry.merge([snapshot(.local, [discovered])],
            projects: &projects, sessions: &sessions, deletedKeys: [], selectedSessionID: id, store: store)
        try require(sessions[0].id == id && sessions[0].projectID == projectID && sessions[0].title == "User title",
                    "discovery preserves local session/project identity and user title")
        try require(try store.loadMessages(for: id).map(\.id) == [replacement.id],
                    "newer local same-count history replaces cached messages")
        discovered.messages.append(Message(origin: .agent, content: [.text("new answer")]))
        discovered.updatedAt = Date(timeIntervalSince1970: 300)
        try SessionDiscoveryRegistry.merge([snapshot(.local, [discovered])],
            projects: &projects, sessions: &sessions, deletedKeys: [], selectedSessionID: nil, store: store)
        try require(sessions[0].markedUnreadAt == discovered.updatedAt && sessions[0].messageCount == 2,
                    "new assistant content marks a nonselected session unread")

        let remote = DiscoveredMachine(id: BackendID("ssh:synthetic-registry"), name: "Fixture", sshAlias: "fixture")
        try SessionDiscoveryRegistry.merge([snapshot(remote, [discovered])],
            projects: &projects, sessions: &sessions, deletedKeys: [], selectedSessionID: nil, store: store)
        guard let remoteRecord = sessions.first(where: { $0.backendID == remote.id }) else {
            throw Failure(reason: "Missing remote fixture record")
        }
        try require(projects.count == 2 && remoteRecord.projectID != projectID,
                    "same directory and provider token stay isolated by backend")
        let cachedIDs = try store.loadMessages(for: remoteRecord.id).map(\.id)
        discovered.messages = [
            Message(origin: .user, content: [.text("remote replacement")]),
            Message(origin: .agent, content: [.text("remote replacement")])
        ]
        discovered.updatedAt = Date(timeIntervalSince1970: 400)
        try SessionDiscoveryRegistry.merge([snapshot(remote, [discovered])],
            projects: &projects, sessions: &sessions, deletedKeys: [], selectedSessionID: nil, store: store)
        try require(try store.loadMessages(for: remoteRecord.id).map(\.id) == cachedIDs,
                    "same-count remote snapshot cannot overwrite cached full history")
        discovered.providerSessionID = "synthetic-deleted-thread"
        let tombstone = DiscoverySessionKey(backendID: remote.id, providerID: .codex,
                                           resumeToken: discovered.providerSessionID)
        try SessionDiscoveryRegistry.merge([snapshot(remote, [discovered])],
            projects: &projects, sessions: &sessions, deletedKeys: [tombstone], selectedSessionID: nil, store: store)
        try require(sessions.count == 2, "deleted discovery identity cannot be reimported")
        let restoredKey = try JSONDecoder().decode(DiscoverySessionKey.self, from: JSONEncoder().encode(tombstone))
        try require(restoredKey == tombstone, "discovery tombstone storage remains compatible")
        print("PASS: discovery deduplication, local/remote history, identity, unread and tombstones")
    }

    static func library() throws {
        let manual = Project(name: "Manual")
        let empty = Project(name: "Empty", metadata: ["discovered": "true"])
        let pinned = Project(name: "Pinned", metadata: ["discovered": "true", "pinned": "true"])
        let discovered = Project(name: "Discovered", metadata: ["discovered": "true"])
        var newest = SessionRecord(projectID: discovered.id, providerID: .codex, title: "Newest")
        newest.updatedAt = Date(timeIntervalSince1970: 300)
        var marked = SessionRecord(projectID: discovered.id, providerID: .codex, title: "Pinned session")
        marked.pinMode = .global
        marked.updatedAt = Date(timeIntervalSince1970: 100)
        var archived = SessionRecord(projectID: discovered.id, providerID: .codex, title: "Archived needle")
        archived.isArchived = true
        let records = [newest, marked, archived]
        let projects = [manual, empty, discovered, pinned]
        try require(SessionLibraryQuery.projects(projects, sessions: records, query: "").map(\.id)
                    == [pinned.id, manual.id, discovered.id], "sidebar visibility and pinned order remain stable")
        try require(SessionLibraryQuery.projects(projects, sessions: records, query: "needle").map(\.id)
                    == [discovered.id], "project title search retains historical archived-title matching")
        try require(SessionLibraryQuery.sessions(records, in: discovered, query: "").map(\.id)
                    == [marked.id, newest.id], "session pin priority and archive hiding remain stable")
        try require(SessionLibraryQuery.sessions(records, in: discovered, query: "discovered").count == 2,
                    "matching project title shows all its visible sessions")
        try require(SessionLibraryQuery.sessions(records, in: discovered, query: "NEWEST").map(\.id)
                    == [newest.id], "session search is case-insensitive")
        let unassigned = SessionRecord(providerID: .codex, title: "needle")
        try require(SessionLibraryQuery.projects([manual, empty], sessions: [unassigned], query: "needle").isEmpty,
                    "unassigned matching session cannot make a project visible")
        try require(SessionLibraryQuery.projects([discovered], sessions: [archived], query: "needle").isEmpty,
                    "archived-only discovered project stays hidden even when its title matches")
        print("PASS: sidebar project/session projection, archived visibility, pins and search")
    }

    @MainActor
    static func eventually(_ name: String, _ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure(reason: "Timed out: \(name)")
    }

    static func require(_ condition: Bool, _ name: String) throws {
        if !condition { throw Failure(reason: name) }
    }
    private struct Failure: Error { let reason: String }
}
