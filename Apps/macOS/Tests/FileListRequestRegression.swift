import Foundation

// Own deterministic list service only. The runner inserts the actual view's
// loadEntries body, exposing its created Task solely to await exact completion.
private struct FileEntry: Sendable {
    let name: String
}

private final class ListRequest: @unchecked Sendable {
    enum Outcome { case entries(String), failure(String) }
    let outcome: Outcome
    private let condition = NSCondition()
    private var released: Bool
    private var didStart = false
    var started: Bool { condition.lock(); defer { condition.unlock() }; return didStart }

    init(_ outcome: Outcome, held: Bool = false) {
        self.outcome = outcome
        released = !held
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func run() throws -> [FileEntry] {
        condition.lock()
        didStart = true
        condition.broadcast()
        let deadline = Date().addingTimeInterval(3)
        while !released, condition.wait(until: deadline) {}
        let ready = released
        condition.unlock()
        guard ready else { throw NSError(domain: "OwnedListGate", code: 1) }
        switch outcome {
        case .entries(let name): return [FileEntry(name: name)]
        case .failure(let reason):
            throw NSError(domain: "OwnedListFailure", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }
}

private final class ListService: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [ListRequest]
    init(_ requests: [ListRequest]) { self.requests = requests }
    func load() throws -> [FileEntry] {
        lock.lock()
        let request = requests.isEmpty ? nil : requests.removeFirst()
        lock.unlock()
        guard let request else { throw NSError(domain: "UnexpectedListRequest", code: 1) }
        return try request.run()
    }
    func entries(in directory: String) throws -> [FileEntry] { try load() }
    func changes() throws -> [FileEntry] { try load() }
}

@MainActor
private final class ListHarness {
    enum Tab { case directories, changes }
    var tab = Tab.directories
    var directory = "/owned-fixture"
    var entries: [FileEntry] = []
    var entriesRequestID = UUID()
    var isLoading = false
    var errorMessage: String?
    let browser: ListService
    init(_ requests: [ListRequest]) { browser = ListService(requests) }
    // PRODUCTION_LOAD_ENTRIES
}

@main
@MainActor
enum FileListRequestRegression {
    static func main() async {
        do { try await verify() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    private static func verify() async throws {
        var failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            print("\(value ? "PASS" : "FAIL"): \(label)")
            if !value { failures.append(label) }
        }
        func started(_ request: ListRequest) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while !request.started, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            if !request.started { throw NSError(domain: "ListFixtureStartTimeout", code: 1) }
        }

        for failure in [false, true] {
            let old = ListRequest(failure ? .failure("obsolete error") : .entries("obsolete list"), held: true)
            defer { old.release() }
            let model = ListHarness([old, ListRequest(.entries("current list"))])
            let first = model.loadEntries()
            try await started(old)
            await model.loadEntries().value
            check(model.entries.map(\.name) == ["current list"] && !model.isLoading,
                  "\(failure): fresh same-directory refresh completes independently")
            old.release()
            await first.value
            check(model.entries.map(\.name) == ["current list"] && model.errorMessage == nil && !model.isLoading,
                  "\(failure): obsolete success/error cannot overwrite a newer same-directory result")
        }

        let oldA = ListRequest(.entries("obsolete A"), held: true)
        defer { oldA.release() }
        let aba = ListHarness([oldA, ListRequest(.entries("B")), ListRequest(.entries("fresh A"))])
        let firstA = aba.loadEntries()
        try await started(oldA)
        aba.directory = "/owned-fixture/B"
        await aba.loadEntries().value
        aba.directory = "/owned-fixture"
        await aba.loadEntries().value
        oldA.release()
        await firstA.value
        check(aba.entries.map(\.name) == ["fresh A"], "A-B-A navigation rejects an old request for the same final directory")

        let early = ListRequest(.entries("obsolete early"), held: true)
        let current = ListRequest(.entries("current late"), held: true)
        defer { early.release(); current.release() }
        let loading = ListHarness([early, current])
        let earlyTask = loading.loadEntries()
        try await started(early)
        let currentTask = loading.loadEntries()
        try await started(current)
        early.release()
        await earlyTask.value
        check(loading.isLoading && loading.entries.isEmpty,
              "obsolete completion cannot clear the current loading indicator or publish stale entries")
        current.release()
        await currentTask.value
        check(!loading.isLoading && loading.entries.map(\.name) == ["current late"],
              "current completion publishes entries and clears its loading indicator")

        let oldGit = ListRequest(.failure("not a git repository: owned fixture"), held: true)
        defer { oldGit.release() }
        let git = ListHarness([oldGit, ListRequest(.entries("current changes"))])
        git.tab = .changes
        let oldGitTask = git.loadEntries()
        try await started(oldGit)
        await git.loadEntries().value
        oldGit.release()
        await oldGitTask.value
        check(git.tab == .changes && git.entries.map(\.name) == ["current changes"] && git.errorMessage == nil,
              "obsolete not-git failure cannot switch a newer successful Changes tab")

        let currentError = ListHarness([ListRequest(.failure("current failure"))])
        await currentError.loadEntries().value
        check(currentError.errorMessage == "current failure" && !currentError.isLoading,
              "current error remains visible and settles loading")
        let currentGit = ListHarness([ListRequest(.failure("not a git repository: current"))])
        currentGit.tab = .changes
        await currentGit.loadEntries().value
        check(currentGit.tab == .directories && currentGit.errorMessage == nil && !currentGit.isLoading,
              "current not-git failure retains the intended Directories fallback")
        if !failures.isEmpty {
            throw NSError(domain: "FileListRequestFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")])
        }
    }
}
