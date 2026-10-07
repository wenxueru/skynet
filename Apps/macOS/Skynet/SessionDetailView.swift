import AppKit
import SkynetCore
import SwiftUI

struct SessionDetailView: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @State private var title = ""
    @State private var isEditingTitle = false
    @FocusState private var isTitleFocused: Bool
    @State private var isOutlinePresented = false
    @State private var isEnvironmentPresented = false
    @State private var isSidePanelMenuPresented = false
    @State private var terminalMode: IntegratedTerminalView.Mode?
    @State private var isFilesPresented = false
    @State private var isBrowserPresented = false
    @State private var fileBrowserTab: SessionFilesView.Tab = .changes
    @State private var outlineQuery = ""
    @State private var outlineJump: SessionTranscriptView.Jump?

    private struct OutlineEntry: Identifiable {
        let id: String
        let title: String
        let createdAt: Date
    }

    var body: some View {
        SessionComposerView(model: model, draft: $draft) {
            header
            Divider()
            SessionTranscriptView(model: model, outlineJump: outlineJump) { quote in
                draft += (draft.isEmpty ? "" : "\n\n") + quote + "\n\n"
            }
        }
        .background { sidePanelShortcuts }
        .onAppear {
            title = model.selectedSession?.title ?? "New session"
        }
        .onChange(of: model.selectedSessionID) { _, _ in
            isEditingTitle = false
            isTitleFocused = false
            title = model.selectedSession?.title ?? "New session"
        }
        .onChange(of: model.selectedSession?.title) { _, newTitle in
            if !isEditingTitle { title = newTitle ?? "New session" }
        }
        .onChange(of: isTitleFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused && isEditingTitle {
                finishTitleEditing(saveChanges: true)
            }
        }
        .sheet(isPresented: permissionDialogPresented) {
            ToolPermissionSheet(
                requestDescription: permissionRequestDescription,
                answer: model.permissionDecisionAction,
                stopTurn: model.permissionTurnStopAction
            )
        }
        .sheet(item: $terminalMode) { mode in
            if let session = model.selectedSession {
                if mode == .sideChat, let provider = model.selectedProvider, provider.kind == .codex {
                    CodexSideChatView(session: session, provider: provider,
                                      backend: model.executionBackend(for: session))
                } else {
                    IntegratedTerminalView(
                    mode: mode,
                    session: session,
                    provider: model.selectedProvider
                    )
                }
            }
        }
        .sheet(isPresented: $isFilesPresented) {
            if let session = model.selectedSession,
               let root = model.selectedProject?.rootPath ?? session.workingDirectory {
                SessionFilesView(session: session, rootPath: root, initialTab: fileBrowserTab) { path in
                    let reference = "`\(path)`"
                    draft += draft.isEmpty ? reference : " \(reference)"
                }
            }
        }
        .sheet(isPresented: $isBrowserPresented) {
            SessionBrowserView()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let session = model.selectedSession {
                ProviderIcon(providerID: session.providerID, isRunning: session.status == .running)
            }
            if isEditingTitle {
                TextField("Session name", text: $title)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .focused($isTitleFocused)
                    .onSubmit { finishTitleEditing(saveChanges: true) }
                    .onExitCommand { finishTitleEditing(saveChanges: false) }
            } else {
                Button {
                    isEditingTitle = true
                    isTitleFocused = true
                } label: {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Rename session")
            }
            Spacer(minLength: 0)
            if model.isSelectedSessionRunning {
                ProgressView().controlSize(.small)
            }
            Button {
                isSidePanelMenuPresented.toggle()
            } label: {
                Image(systemName: "rectangle.split.2x1")
                    .frame(width: 30, height: 30)
                    .background(isSidePanelMenuPresented ? Color.accentColor.opacity(0.16) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSidePanelMenuPresented ? Color.accentColor : .secondary)
            .help("Toggle side panel")
            .popover(isPresented: $isSidePanelMenuPresented, arrowEdge: .bottom) {
                sidePanelMenu
            }
            Button {
                isEnvironmentPresented.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Environment and activity")
            .popover(isPresented: $isEnvironmentPresented, arrowEdge: .bottom) {
                environmentPanel
            }
            Button {
                isOutlinePresented.toggle()
            } label: {
                Image(systemName: "list.bullet")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Conversation outline")
            .popover(isPresented: $isOutlinePresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Search outline", text: $outlineQuery)
                        .textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(filteredOutlineEntries) { entry in
                                Button {
                                    outlineJump = SessionTranscriptView.Jump(groupID: entry.id)
                                    isOutlinePresented = false
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.title).lineLimit(2)
                                        Text(entry.createdAt, style: .date)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(7)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(width: 300, height: 360)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    (NSApp.keyWindow ?? NSApp.mainWindow)?.performZoom(nil)
                }
        }
    }

    private var environmentPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Environment")
                    .font(.headline)

                if let session = model.selectedSession {
                    environmentValue(
                        "Project",
                        value: model.selectedProject?.rootPath
                            ?? session.workingDirectory ?? "No working directory",
                        icon: "folder"
                    )
                    environmentValue(
                        "Remote",
                        value: session.backendID.flatMap { id in
                            id.rawValue.hasPrefix("ssh:")
                                ? String(id.rawValue.dropFirst("ssh:".count)) : nil
                        } ?? "This Mac",
                        icon: "globe"
                    )
                }

                Divider()

                activitySection(
                    "Subagent activity",
                    icon: "person.2",
                    tools: subagentTools,
                    emptyMessage: "No subagent activity reported"
                )

                Divider()

                activitySection(
                    "Background processes",
                    icon: "terminal",
                    tools: backgroundTools,
                    emptyMessage: model.isSelectedSessionRunning
                        ? "No background process reported yet"
                        : "No background processes"
                )

                Text("Activity shown here is based on events reported by the active provider.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(width: 340, height: 460)
    }

    private func environmentValue(_ title: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.secondary)
                Text(value)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private func activitySection(
        _ title: String,
        icon: String,
        tools: [AppModel.LiveTool],
        emptyMessage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if !tools.isEmpty {
                    Text("\(tools.count) reported")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            if tools.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(tools) { tool in
                    activityRow(tool)
                }
            }
        }
    }

    private func activityRow(_ tool: AppModel.LiveTool) -> some View {
        let activity = ToolActivityPresentation(
            name: tool.name, input: tool.input, output: tool.output, isError: tool.isError,
            subagentStatus: tool.subagentStatus
        )
        let appearance: (symbol: String, color: Color) = switch activity.status {
        case .running: ("circle.dotted", .accentColor)
        case .failed: ("exclamationmark.circle", .red)
        case .inactive: ("pause.circle", .secondary)
        case .completed: ("checkmark.circle.fill", .secondary)
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: appearance.symbol)
                .foregroundStyle(appearance.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(activityTitle(for: tool))
                    .lineLimit(2)
                Text("\(activity.statusLabel) · \(activity.detail)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private var subagentTools: [AppModel.LiveTool] {
        guard model.hasSelectedSessionActivity else { return [] }
        return model.liveTools.filter(isSubagentTool)
    }

    private var backgroundTools: [AppModel.LiveTool] {
        guard model.hasSelectedSessionActivity else { return [] }
        return model.liveTools.filter { tool in
            guard !isSubagentTool(tool) else { return false }
            let isExplicitlyBackground = [
                "run_in_background", "runInBackground", "background", "is_background",
            ].contains { tool.input[$0]?.boolValue == true }
            let isActiveCommand = tool.output == nil
                && ["bash", "codexbash"].contains(tool.name.lowercased())
            return isExplicitlyBackground || isActiveCommand
        }
    }

    private func isSubagentTool(_ tool: AppModel.LiveTool) -> Bool {
        let name = tool.name.lowercased()
        let shortName = name.split(separator: "_").last.map(String.init) ?? name
        return ["task", "agent", "codexagent"].contains(shortName)
            || name.contains("subagent")
            || name.contains("spawn_agent")
    }

    private func activityTitle(for tool: AppModel.LiveTool) -> String {
        let detail = ["description", "command", "task", "prompt", "subagent_type"]
            .compactMap { tool.input[$0]?.stringValue }
            .first { !$0.isEmpty }
        guard let detail else { return tool.name }
        let oneLine = detail
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return oneLine.count > 100 ? String(oneLine.prefix(99)) + "…" : oneLine
    }

    private func finishTitleEditing(saveChanges: Bool) {
        guard isEditingTitle else { return }
        isEditingTitle = false
        isTitleFocused = false
        if saveChanges { model.renameSelectedSession(title) }
        title = model.selectedSession?.title ?? "New session"
    }

    private var filteredOutlineEntries: [OutlineEntry] {
        let entries = model.transcriptGroups.compactMap { group -> OutlineEntry? in
            guard case .message(let id, let message) = group,
                  message.origin == .user else { return nil }
            let text = message.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = text.isEmpty ? "Image" : String(text.prefix(140))
            return OutlineEntry(id: id, title: title, createdAt: message.createdAt)
        }
        let query = outlineQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? entries : entries.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    private var sidePanelMenu: some View {
        VStack(spacing: 4) {
            sidePanelAction("Review", icon: "rectangle.on.rectangle", shortcut: "⌃⇧G",
                            disabled: !canBrowseFiles) {
                openFiles(tab: .changes)
            }
            sidePanelAction("Terminal", icon: "terminal", shortcut: "⌃`") {
                terminalMode = .shell
            }
            sidePanelAction("Browser", icon: "globe", shortcut: "⌘T") {
                isBrowserPresented = true
            }
            sidePanelAction("Files", icon: "folder", shortcut: "⌘P",
                            disabled: !canBrowseFiles) {
                openFiles(tab: .directories)
            }
            Divider().padding(.vertical, 4)
            sidePanelAction("Side chat", icon: "bubble.left.and.bubble.right", shortcut: "⌥⌘S",
                            disabled: !canOpenNativeSideChat) {
                terminalMode = .sideChat
            }
            .help(model.selectedProvider?.kind == .codex
                  ? "Open a temporary, read-only side conversation with this session’s context"
                  : "Open the resumed interactive CLI, then enter /btw")
        }
        .padding(8)
        .frame(width: 260)
    }

    private var canBrowseFiles: Bool {
        (model.selectedProject?.rootPath ?? model.selectedSession?.workingDirectory) != nil
    }

    // Popover content exists only while open; shortcuts must live in the main view.
    private var sidePanelShortcuts: some View {
        HStack {
            Button("Review") { openFiles(tab: .changes) }
                .keyboardShortcut("g", modifiers: [.control, .shift])
                .disabled(!canBrowseFiles)
            Button("Terminal") {
                isSidePanelMenuPresented = false
                terminalMode = .shell
            }
                .keyboardShortcut(KeyEquivalent("`"), modifiers: [.control])
            Button("Browser") {
                isSidePanelMenuPresented = false
                isBrowserPresented = true
            }
                .keyboardShortcut("t", modifiers: .command)
            Button("Files") { openFiles(tab: .directories) }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!canBrowseFiles)
            Button("Side chat") {
                isSidePanelMenuPresented = false
                terminalMode = .sideChat
            }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!canOpenNativeSideChat)
        }
        .disabled(model.selectedSession == nil || terminalMode != nil
                  || isFilesPresented || isBrowserPresented)
        .hidden()
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var canOpenNativeSideChat: Bool {
        guard let provider = model.selectedProvider,
              model.selectedSession?.providerResumeToken != nil else { return false }
        return provider.kind == .codex || provider.kind == .claudeCode
            || provider.kind == .claudeCodeCompatible
    }

    private func openFiles(tab: SessionFilesView.Tab) {
        isSidePanelMenuPresented = false
        fileBrowserTab = tab
        isFilesPresented = true
    }

    private func sidePanelAction(
        _ title: String,
        icon: String,
        shortcut: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            isSidePanelMenuPresented = false
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
                Text(shortcut)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var permissionDialogPresented: Binding<Bool> {
        let answer = model.permissionDecisionAction
        return Binding(
            get: { model.pendingPermissionRequest != nil },
            set: { if !$0 { answer(.deny) } }
        )
    }

    private var permissionRequestDescription: String {
        guard let request = model.pendingPermissionRequest else { return "" }
        return [model.pendingPermissionSessionTitle, request.summary, request.primaryArgument]
            .compactMap { $0 }.joined(separator: "\n\n")
    }

}

// A regular sheet button performs its action before the binding dismisses the
// sheet. confirmationDialog can instead clear/rebuild conditional actions first,
// causing Stop to become only the binding's default denial on macOS.
private struct ToolPermissionSheet: View {
    let requestDescription: String
    let answer: (PermissionResponse.Decision) -> Void
    let stopTurn: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Allow this tool?", systemImage: "hand.raised")
                .font(.headline)
            ScrollView {
                Text(requestDescription)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            HStack {
                if let stopTurn {
                    Button("Stop turn", role: .destructive, action: stopTurn)
                }
                Spacer()
                Button("Deny", role: .destructive) { answer(.deny) }
                    .keyboardShortcut(.cancelAction)
            }
            HStack {
                Spacer()
                Button("Always allow this session") { answer(.allowAlways) }
                Button("Allow once") { answer(.allow) }
            }
        }
        .buttonStyle(.bordered)
        .padding(24)
        .frame(width: 540)
    }
}
