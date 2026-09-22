import AppKit
import SkynetCore
import SwiftUI

struct ProviderSettingsView: View {
    @Bindable var model: AppModel
    @State private var selection: SettingsCategory = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selection) { category in
                Label(category.title, systemImage: category.icon).tag(category)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
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
        case .about: AboutSettingsView()
        }
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, agents, ssh, storage, about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .agents: "Agents"
        case .ssh: "SSH Connections"
        case .storage: "Storage"
        case .about: "About"
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .agents: "terminal"
        case .ssh: "network"
        case .storage: "internaldrive"
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
                    HStack(spacing: 10) {
                        Circle()
                            .fill(model.machineErrors[machine.id] == nil ? .green : .red)
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
                    }
                }
            }
        }
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
