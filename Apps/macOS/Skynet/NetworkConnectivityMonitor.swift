import Foundation
import Network
import Observation
import SkynetCore

/// Connectivity is independent of history discovery and never clears cached sessions.
@MainActor
@Observable
final class NetworkConnectivityMonitor {
    enum Status: Equatable, Sendable {
        case checking
        case reachable
        case unavailable(String)

        var failure: String? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
    }

    typealias Probe = @Sendable (String) async -> Status
    private(set) var networkAvailable: Bool?
    private(set) var hosts: [BackendID: Status] = [:]
    @ObservationIgnored private var targets: [BackendID: String] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private let pathMonitor: NWPathMonitor?
    @ObservationIgnored private let probe: Probe
    @ObservationIgnored private let interval: Duration

    init(
        monitorNetwork: Bool = true,
        interval: Duration = .seconds(30),
        probe: @escaping Probe = { await SSHConnectivityProbe.check($0) }
    ) {
        self.probe = probe
        self.interval = interval
        let monitor = monitorNetwork ? NWPathMonitor() : nil
        pathMonitor = monitor
        monitor?.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in self?.updateNetwork(available: available) }
        }
        monitor?.start(queue: DispatchQueue(label: "Skynet.connectivity"))
    }

    deinit {
        pathMonitor?.cancel()
        pollingTask?.cancel()
    }

    func configure(machines: [DiscoveredMachine]) {
        let updated = Dictionary(uniqueKeysWithValues: machines.compactMap { machine in
            machine.sshAlias.map { (machine.id, $0) }
        })
        guard targets != updated else { return }
        var statuses: [BackendID: Status] = [:]
        for (id, alias) in updated {
            if targets[id] == alias, let existing = hosts[id] {
                statuses[id] = existing
            } else {
                statuses[id] = .checking
            }
        }
        hosts = statuses
        targets = updated
        restart()
    }

    func updateNetwork(available: Bool) {
        guard networkAvailable != available else { return }
        networkAvailable = available
        restart()
    }

    private func restart() {
        generation = UUID()
        pollingTask?.cancel()
        pollingTask = nil
        guard networkAvailable != false else {
            hosts = targets.mapValues { _ in .unavailable("Network unavailable.") }
            return
        }
        guard !targets.isEmpty else { return }
        // Recovery starts from unknown, not the old disconnected result.
        if hosts.values.contains(where: { $0.failure == "Network unavailable." }) {
            hosts = targets.mapValues { _ in .checking }
        }
        let token = generation
        let targets = targets
        let probe = probe
        let interval = interval
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await withTaskGroup(of: (BackendID, Status).self) { group in
                    var remaining = targets.makeIterator()
                    func enqueueNext() {
                        guard !Task.isCancelled, let (id, alias) = remaining.next() else { return }
                        group.addTask { (id, await probe(alias)) }
                    }
                    for _ in 0..<min(4, targets.count) { enqueueNext() }
                    for await (id, status) in group {
                        guard !Task.isCancelled, self?.generation == token else {
                            group.cancelAll()
                            return
                        }
                        self?.hosts[id] = status
                        enqueueNext()
                    }
                }
                do { try await Task.sleep(for: interval) }
                catch { return }
            }
        }
    }
}

enum SSHConnectivityProbe {
    /// Read-only command over the same reusable transport as normal SSH operations.
    /// A hard deadline also bounds slow proxies/login shells; both pipes are drained.
    static func check(
        _ alias: String, launcher: any ExecutionBackend = LocalProcessBackend(),
        timeout: Duration = .seconds(10)
    ) async -> NetworkConnectivityMonitor.Status {
        do {
            try Task.checkCancellation()
            let process = try await launcher.launch(ExecutionRequest(
                executable: "/usr/bin/ssh",
                arguments: ["-oBatchMode=yes", "-oConnectTimeout=5",
                    "-oServerAliveInterval=5", "-oServerAliveCountMax=1"]
                    + SSHBackend.connectionReuseOptions + ["--", alias, "true"],
                stdinMode: .closed, label: "connectivity:\(alias)"
            ))
            let deadline = Task {
                do { try await Task.sleep(for: timeout) }
                catch { return }
                await process.terminate()
            }
            defer { deadline.cancel() }
            return try await withTaskCancellationHandler {
                async let output: Void = drain(process.stdoutLines)
                async let diagnostics = diagnosticText(process.stderrLines)
                let exitCode = try await process.waitUntilExit()
                let (_, stderr) = try await (output, diagnostics)
                try Task.checkCancellation()
                if exitCode == 0 { return .reachable }
                return .unavailable(SSHBackend.failureReason(
                    operation: "Connectivity check", exitCode: exitCode, stderr: stderr
                ))
            } onCancel: {
                Task { await process.terminate() }
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private static func drain(_ lines: AsyncThrowingStream<String, Error>) async throws {
        for try await _ in lines {}
    }

    private static func diagnosticText(_ lines: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await line in lines where text.utf8.count < 4096 {
            text += String(line.prefix(1024)) + "\n"
        }
        return text
    }
}
