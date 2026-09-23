import AppKit
import SkynetCore
import SwiftUI

struct ProviderSettingsView: View {
    @Bindable var model: AppModel
    @State private var selection: SettingsCategory = .general

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsCategory.allCases, selection: $selection) { category in
                Label(category.title, systemImage: category.icon).tag(category)
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            settingsPage.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var settingsPage: some View {
        switch selection {
        case .general: GeneralSettingsView()
        case .agents: AgentSettingsView(model: model)
        case .ssh: SSHSettingsView(model: model)
        case .storage: StorageSettingsView(model: model)
        case .usage: UsageSettingsView(model: model)
        case .about: AboutSettingsView()
        }
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, agents, ssh, storage, usage, about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .agents: "Agents"
        case .ssh: "SSH Connections"
        case .storage: "Storage"
        case .usage: "Usage"
        case .about: "About"
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .agents: "terminal"
        case .ssh: "network"
        case .storage: "internaldrive"
        case .usage: "chart.bar"
        case .about: "info.circle"
        }
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(AppPreferenceKey.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(AppPreferenceKey.showTimestamps) private var showTimestamps = true
    @AppStorage(AppPreferenceKey.expandReasoning) private var expandReasoning = false
    @AppStorage(AppPreferenceKey.expandTools) private var expandTools = false

    var body: some View {
        SettingsForm(title: "General") {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                }
                .pickerStyle(.segmented)
            }
            Section("Conversation") {
                Toggle("Show message timestamps", isOn: $showTimestamps)
                Toggle("Expand reasoning by default", isOn: $expandReasoning)
                Toggle("Expand tool details by default", isOn: $expandTools)
            }
        }
    }
}

private struct AgentSettingsView: View {
    @Bindable var model: AppModel
    @State private var name = ""
    @State private var executable = ""
    @State private var arguments = ""

    var body: some View {
        SettingsForm(title: "Agents") {
            Section("Built in") {
                providerRow(name: "Codex", executable: "codex")
                providerRow(name: "Claude Code", executable: "claude")
            }
            Section("Compatible agents") {
                ForEach(customProviders, id: \.id) { provider in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(provider.displayName)
                            Text(provider.executable ?? "Provider default")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Delete", role: .destructive) { model.deleteCustomProvider(provider.id) }
                    }
                }
                if customProviders.isEmpty {
                    Text("No additional compatible agents configured").foregroundStyle(.secondary)
                }
            }
            Section("Add Claude Code-compatible agent") {
                TextField("Display name", text: $name)
                TextField("Executable path", text: $executable)
                TextField("Default arguments", text: $arguments)
                HStack {
                    Spacer()
                    Button("Add agent", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || executable.isEmpty)
                }
            }
        }
    }

    private var customProviders: [AgentProviderDescriptor] {
        model.providers.filter { $0.id != .codex && $0.id != .claudeCode }
    }

    private func providerRow(name: String, executable: String) -> some View {
        LabeledContent(name) {
            Text(executable).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func save() {
        model.saveCustomProvider(name: name, executable: executable, arguments: arguments)
        name = ""
        executable = ""
        arguments = ""
    }
}

private struct SSHSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsForm(title: "SSH Connections") {
            Section {
                Text("Hosts are read automatically from ~/.ssh/config, including Include files. Session history is discovered over SSH without modifying the remote host.")
                    .foregroundStyle(.secondary)
                Button("Refresh", systemImage: "arrow.clockwise", action: model.refreshDiscovery)
                    .disabled(model.isDiscovering)
            }
            Section("Machines") {
                ForEach(model.machines) { machine in
                    let isEnabled = model.isMachineEnabled(machine.id)
                    Button {
                        model.setMachine(machine.id, enabled: !isEnabled)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isEnabled ? "checkmark.square.fill" : "square")
                                .foregroundStyle(isEnabled ? .blue : .secondary)
                            Circle()
                                .fill(statusColor(for: machine))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(machine.name)
                                if let alias = machine.sshAlias {
                                    Text(alias).font(.caption).foregroundStyle(.secondary)
                                }
                                if let error = model.machineErrors[machine.id] {
                                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(machine.name)
                    .accessibilityValue(isEnabled ? "Enabled" : "Disabled")
                }
            }
        }
    }

    private func statusColor(for machine: DiscoveredMachine) -> Color {
        guard model.isMachineEnabled(machine.id) else { return .secondary }
        return model.machineErrors[machine.id] == nil ? .green : .red
    }
}

private struct StorageSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsForm(title: "Storage") {
            Section("Local data") {
                LabeledContent("Projects", value: model.projects.count.formatted())
                LabeledContent("Sessions", value: model.sessions.count.formatted())
                LabeledContent("Messages", value: model.sessions.reduce(0) { $0 + $1.messageCount }.formatted())
            }
            if let url = model.storageDirectoryURL {
                Section("Location") {
                    Text(url.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
    }
}

private struct UsageSettingsView: View {
    @Bindable var model: AppModel
    @State private var range: SessionUsageRange = .sevenDays
    @State private var summary: SessionUsageSummary?
    @State private var loadError: String?

    var body: some View {
        SettingsForm(title: "Usage") {
            Section {
                Picker("Period", selection: $range) {
                    ForEach(SessionUsageRange.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
            if let loadError {
                Section { Text(loadError).foregroundStyle(.red) }
            } else if let summary {
                Section("Token usage") {
                    LabeledContent("Total", value: formatted(summary.totals.totalTokens))
                    LabeledContent("Input", value: formatted(summary.totals.usage.inputTokens))
                    LabeledContent("Output", value: formatted(summary.totals.usage.outputTokens))
                    LabeledContent("Cache read", value: formatted(summary.totals.usage.cacheReadTokens))
                    LabeledContent("Cache written", value: formatted(summary.totals.usage.cacheWriteTokens))
                    LabeledContent("Usage entries", value: summary.totals.requests.formatted())
                }
                usageSection("Daily", buckets: summary.daily)
                usageSection("Agents", buckets: summary.byAgent)
                usageSection("Models", buckets: summary.byModel)
                if summary.sessionsMissingUsage > 0 {
                    Section {
                        Text("\(summary.sessionsMissingUsage) sessions have no token usage reported by their provider. Totals may be incomplete.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Historical Codex usage is a session total, assigned to its last activity date. Daily bars and entry counts are approximate; they are not per-request billing data.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section { ProgressView("Loading usage…") }
            }
        }
        .task(id: range) {
            summary = nil
            loadError = nil
            do {
                let result = try await model.loadUsageSummary(range: range)
                guard !Task.isCancelled else { return }
                summary = result
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func usageSection(_ title: String, buckets: [UsageBucket]) -> some View {
        Section(title) {
            if buckets.isEmpty {
                Text("No reported usage in this period").foregroundStyle(.secondary)
            } else {
                let maximum = max(buckets.map(\.totalTokens).max() ?? 0, 1)
                ForEach(buckets) { bucket in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(bucket.key)
                            Spacer()
                            Text(formatted(bucket.totalTokens)).foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(bucket.totalTokens), total: Double(maximum))
                            .tint(.accentColor)
                        Text("\(bucket.requests.formatted()) entries · \(formatted(bucket.usage.inputTokens)) input · \(formatted(bucket.usage.outputTokens)) output")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func formatted(_ value: Int?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.notation(.compactName))
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        SettingsForm(title: "About") {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Skynet").font(.title2.weight(.semibold))
                        Text("Distributed AI sessions, in one place.").foregroundStyle(.secondary)
                        Text(version).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "Development"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }
}

private struct SettingsForm<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            Text(title).font(.largeTitle.bold()).padding(.bottom, 6)
            content
        }
        .formStyle(.grouped)
        .padding()
    }
}
