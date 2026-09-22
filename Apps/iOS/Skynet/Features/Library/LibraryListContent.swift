import SwiftUI

/// Shared machine/project list used by the compact home screen and the iPad
/// sidebar. One `Section` per machine, projects as rows.
struct LibraryListContent: View {
    let model: LibraryViewModel
    /// Project to highlight (iPad sidebar selection); nil on compact.
    let selectedProjectID: ProjectID?
    let onOpenProject: (Project) -> Void

    @State private var machinePendingUnpair: Machine?

    var body: some View {
        List {
            ForEach(model.machines) { machine in
                machineSection(machine)
            }
            ForEach(model.orphanedProjectMachineIDs, id: \.rawValue) { machineID in
                orphanedSection(machineID)
            }
        }
        .confirmationDialog(
            "Forget this Mac?",
            isPresented: Binding(
                get: { machinePendingUnpair != nil },
                set: { if !$0 { machinePendingUnpair = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(
                "Forget \(machinePendingUnpair?.displayName ?? "Mac")",
                role: .destructive
            ) {
                if let machine = machinePendingUnpair {
                    Task { await model.unpair(machine) }
                }
                machinePendingUnpair = nil
            }
            Button("Cancel", role: .cancel) { machinePendingUnpair = nil }
        } message: {
            Text(
                "Sessions stay on the Mac. You'll need to pair again to use it from this device."
            )
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func machineSection(_ machine: Machine) -> some View {
        Section {
            let projects = model.projects(for: machine)
            if projects.isEmpty {
                Text("No projects yet — open the agent app on your Mac.")
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            } else {
                ForEach(projects) { project in
                    projectRow(project)
                }
            }
        } header: {
            MachineSectionHeader(machine: machine)
                .contextMenu {
                    Button(role: .destructive) {
                        machinePendingUnpair = machine
                    } label: {
                        Label("Forget This Mac", systemImage: "minus.circle")
                    }
                    .accessibilityIdentifier(A11yID.Library.unpairAction(machine.id))
                }
        }
    }

    @ViewBuilder
    private func orphanedSection(_ machineID: MachineID) -> some View {
        let projects = model.projectsByMachine[machineID] ?? []
        Section {
            ForEach(projects) { project in
                projectRow(project)
            }
        } header: {
            // Relay returned projects for a machine this device no longer has
            // a record for; show them rather than hiding work.
            Label(machineID.rawValue, systemImage: "desktopcomputer")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.secondary)
        }
    }

    private func projectRow(_ project: Project) -> some View {
        Button {
            onOpenProject(project)
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "folder")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(project.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        if let branch = project.gitBranch {
                            BadgeView(branch, tint: Theme.accent, systemImage: "arrow.triangle.branch")
                        }
                    }
                    Text(project.contextLabel)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if let lastActivityAt = project.lastActivityAt {
                    Text(SkynetFormatters.relativeTime(lastActivityAt))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            selectedProjectID == project.id
                ? Color.accentColor.opacity(0.12)
                : nil
        )
        .accessibilityIdentifier(A11yID.Library.projectRow(project.id))
        .accessibilityAddTraits(.isButton)
    }
}

/// Machine identity + liveness as a section header.
struct MachineSectionHeader: View {
    let machine: Machine

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(Color.secondary)
                .accessibilityHidden(true)
            Text(machine.displayName)
                .font(.footnote.weight(.semibold))
            StatusDotView(
                color: machine.status.isOnline ? Theme.success : Color.secondary,
                isPulsing: machine.status.isOnline
            )
            Text(machine.status.isOnline ? "Online" : "Offline")
                .font(.caption2)
                .foregroundStyle(Color.secondary)
            Spacer()
            Text("\(machine.modelDescription) · \(machine.osVersion)")
                .font(.caption2)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(machine.displayName), \(machine.status.isOnline ? "online" : "offline")"
        )
    }
}

// MARK: - Previews

#Preview("Library list") {
    let environment = AppEnvironment.preview()
    let model = LibraryViewModel(
        machineStore: environment.machineStore,
        pairing: environment.pairing,
        relay: environment.relay,
        sessionIndex: environment.sessionIndex
    )
    return NavigationStack {
        LibraryListContent(model: model, selectedProjectID: nil) { _ in }
            .task { await model.load() }
    }
}
