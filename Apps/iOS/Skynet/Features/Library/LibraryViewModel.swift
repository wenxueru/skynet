import Foundation

/// Backs the machine/project library (compact root and iPad sidebar).
///
/// Machines come from the paired-machine store; projects come from the relay
/// of the currently relevant transport. Both load paths are independent: a
/// Mac that is offline still appears in the list, just without fresh project
/// data.
@MainActor
@Observable
public final class LibraryViewModel {
    public private(set) var machines: [Machine] = []
    /// Projects keyed by the machine they belong to.
    public private(set) var projectsByMachine: [MachineID: [Project]] = [:]
    public private(set) var isLoading = false
    public private(set) var loadError: String?
    public private(set) var isUnpairing = false

    /// True when there is nothing at all to show — the “pair your first Mac”
    /// state.
    public var isEmpty: Bool {
        machines.isEmpty && projectsByMachine.isEmpty
    }

    public var hasProjects: Bool {
        projectsByMachine.values.contains { !$0.isEmpty }
    }

    private let machineStore: any PairedMachineStore
    private let pairing: any PairingService
    private let relay: any SkynetRelay
    private let sessionIndex: SessionIndex

    public init(
        machineStore: any PairedMachineStore,
        pairing: any PairingService,
        relay: any SkynetRelay,
        sessionIndex: SessionIndex
    ) {
        self.machineStore = machineStore
        self.pairing = pairing
        self.relay = relay
        self.sessionIndex = sessionIndex
    }

    // MARK: - Loading

    /// Loads machines and projects. Errors from one source never hide the
    /// other's results: the strongest failure wins the banner, the lists stay
    /// as full as the data allows.
    public func load() async {
        isLoading = true
        defer { isLoading = false }

        var machineError: String?
        var projectError: String?

        if let stored = try? await machineStore.machines() {
            machines = stored
        } else {
            machineError = "Couldn't read paired machines from the Keychain."
        }

        do {
            let projects = try await relay.projects()
            var grouped: [MachineID: [Project]] = [:]
            for project in projects {
                grouped[project.machineID, default: []].append(project)
            }
            for key in grouped.keys {
                grouped[key]?.sort {
                    ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
                }
            }
            projectsByMachine = grouped
            await sessionIndex.register(projects: projects)
        } catch is SkynetError {
            // Not-paired / not-connected is a normal state for this screen.
            projectsByMachine = [:]
        } catch {
            projectError = "Couldn't load projects from your Mac. \(error.localizedDescription)"
            projectsByMachine = [:]
        }

        loadError = projectError ?? machineError
    }

    /// Refreshes after a state change that the relay would reflect
    /// (pairing completed, machine came back online).
    public func refresh() async {
        await load()
    }

    // MARK: - Projects

    public func projects(for machine: Machine) -> [Project] {
        projectsByMachine[machine.id] ?? []
    }

    /// Machine IDs that have projects but no stored machine record —
    /// surfaced so a relay with unknown metadata never hides work.
    public var orphanedProjectMachineIDs: [MachineID] {
        let known = Set(machines.map(\.id))
        return projectsByMachine
            .filter { !$0.value.isEmpty && !known.contains($0.key) }
            .keys
            .sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: - Unpairing

    public func unpair(_ machine: Machine) async {
        isUnpairing = true
        defer { isUnpairing = false }

        do {
            try await pairing.unpair(machine.id)
        } catch {
            // The credential is local; dropping it even if the relay-side
            // revocation failed is the safer outcome.
            Log.library.error("Relay-side unpair failed for \(machine.displayName): \(error)")
        }
        do {
            try await machineStore.forgetMachine(machine.id)
        } catch {
            loadError = "Couldn't remove \(machine.displayName) from this device. \(error.localizedDescription)"
        }
        await load()
    }

    // MARK: - Helpers

    public func statusText(for machine: Machine) -> String {
        machine.status.isOnline ? "Online" : "Offline"
    }
}
