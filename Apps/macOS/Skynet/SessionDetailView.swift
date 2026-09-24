import AppKit
import SkynetCore
import SwiftUI
import UniformTypeIdentifiers

struct SessionDetailView: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var title = ""
    @State private var isEditingTitle = false
    @FocusState private var isTitleFocused: Bool
    @State private var isImageImporterPresented = false
    @State private var isAtBottom = true
    @State private var shouldScrollToLatestAfterLoad = false
    @State private var transcriptViewportHeight: CGFloat = 0
    @State private var composerSelection = NSRange(location: 0, length: 0)
    @State private var composerItems: [ComposerSuggestion] = []
    @State private var selectedSuggestionIndex = 0
    @State private var dismissedCompletion: String?
    @State private var availableModels: [ModelDescriptor] = []
    @State private var modelDefaultEfforts: [ModelID: ReasoningEffort] = [:]
    @State private var isCustomModelPresented = false
    @State private var customModelID = ""
    @State private var isCodexEffortPresented = false
    @State private var isCodexModelListPresented = false
    @State private var isOutlinePresented = false
    @State private var isEnvironmentPresented = false
    @State private var terminalMode: IntegratedTerminalView.Mode?
    @State private var isFilesPresented = false
    @State private var isCustomSchedulePresented = false
    @State private var customScheduleDate = Date().addingTimeInterval(30 * 60)
    @State private var pendingSchedule: PendingSchedule?
    @State private var outlineQuery = ""
    @State private var outlineJump: OutlineJump?

    private struct OutlineJump {
        let nonce = UUID()
        let groupID: String
    }

    private enum PendingSchedule: Equatable {
        case minutes(Int)
        case absolute(Date)

        func fireDate(from now: Date) -> Date {
            switch self {
            case .minutes(let minutes): now.addingTimeInterval(TimeInterval(minutes * 60))
            case .absolute(let date): date
            }
        }
    }

    private struct OutlineEntry: Identifiable {
        let id: String
        let title: String
        let createdAt: Date
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                header
                Divider()
                transcript
                composer
            }
            if isCodexEffortPresented {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { isCodexEffortPresented = false }
                codexEffortPanel
                    .padding(.trailing, 42)
                    .padding(.bottom, 92)
            }
        }
        .onAppear {
            title = model.selectedSession?.title ?? "New session"
            restoreComposerDraft(for: model.selectedSessionID)
        }
        .onChange(of: model.selectedSessionID) { oldID, newID in
            draftSaveTask?.cancel()
            if let oldID, model.sessions.contains(where: { $0.id == oldID }) {
                model.saveComposerDraft(draft, attachments: model.pendingAttachments, for: oldID)
            }
            restoreComposerDraft(for: newID)
            pendingSchedule = nil
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
        .onChange(of: draft) { _, _ in
            selectedSuggestionIndex = 0
            dismissedCompletion = nil
            scheduleDraftSave()
        }
        .onChange(of: model.pendingAttachments) { _, _ in scheduleDraftSave() }
        .onDisappear {
            draftSaveTask?.cancel()
            if let sessionID = model.selectedSessionID {
                model.saveComposerDraft(draft, attachments: model.pendingAttachments, for: sessionID)
            }
        }
        .task(id: composerCatalogID) {
            composerItems = await ComposerCatalog.load(
                projectPath: model.selectedProject?.rootPath,
                providerKind: model.selectedProvider?.kind
            )
        }
        .task(id: modelCatalogID) {
            let provider = model.selectedProvider
            let backendID = model.selectedSession?.backendID?.rawValue ?? "local"
            let catalog = await Task.detached {
                ProviderModelDiscovery.models(for: provider, backendID: backendID)
            }.value
            guard !Task.isCancelled else { return }
            availableModels = catalog.models
            modelDefaultEfforts = catalog.defaultEfforts
        }
        .alert("Custom model ID", isPresented: $isCustomModelPresented) {
            TextField("Model ID", text: $customModelID)
            Button("Use model") {
                let value = customModelID.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { model.updateModel(ModelID(value)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a model or alias supported by this machine's CLI.")
        }
        .confirmationDialog(
            "Allow this tool?",
            isPresented: permissionDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Allow once") { model.answerPermission(.allow) }
            Button("Always allow this session") { model.answerPermission(.allowAlways) }
            Button("Deny", role: .destructive) { model.answerPermission(.deny) }
        } message: {
            Text(permissionRequestDescription)
        }
        .fileImporter(
            isPresented: $isImageImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                urls.forEach(model.attachImage)
            }
        }
        .sheet(item: $terminalMode) { mode in
            if let session = model.selectedSession {
                IntegratedTerminalView(
                    mode: mode,
                    session: session,
                    provider: model.selectedProvider
                )
            }
        }
        .sheet(isPresented: $isFilesPresented) {
            if let session = model.selectedSession,
               let root = model.selectedProject?.rootPath ?? session.workingDirectory {
                SessionFilesView(session: session, rootPath: root) { path in
                    let reference = "`\(path)`"
                    draft += draft.isEmpty ? reference : " \(reference)"
                }
            }
        }
        .popover(isPresented: $isCustomSchedulePresented) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Schedule message").font(.headline)
                DatePicker(
                    "Send at", selection: $customScheduleDate,
                    in: Date().addingTimeInterval(60)...Date().addingTimeInterval(7 * 86_400)
                )
                HStack {
                    Button("Cancel") { isCustomSchedulePresented = false }
                    Spacer()
                    Button("Use time") {
                        pendingSchedule = .absolute(customScheduleDate)
                        isCustomSchedulePresented = false
                    }
                }
            }
            .padding(16)
            .frame(width: 340)
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
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    NSApp.keyWindow?.performZoom(nil)
                }
            if model.isRunning {
                ProgressView().controlSize(.small)
            }
            Button { isFilesPresented = true } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Browse project files")
            .disabled((model.selectedProject?.rootPath ?? model.selectedSession?.workingDirectory) == nil)
            Menu {
                Button("Shell terminal") { terminalMode = .shell }
                Button("Agent terminal") { terminalMode = .agent }
                    .disabled(model.isRunning || model.selectedSession?.providerResumeToken == nil)
            } label: {
                Image(systemName: "terminal")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Terminal")
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
                                    outlineJump = OutlineJump(groupID: entry.id)
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
        .frame(height: 48)
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
                    "Subagents",
                    icon: "person.2",
                    tools: subagentTools,
                    emptyMessage: "No subagent activity reported"
                )

                Divider()

                activitySection(
                    "Background processes",
                    icon: "terminal",
                    tools: backgroundTools,
                    emptyMessage: model.isRunning
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
                    let completed = tools.filter { $0.output != nil }.count
                    Text(completed == tools.count ? "\(completed) done" : "\(tools.count) total")
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tool.output == nil ? "circle.dotted" : "checkmark.circle.fill")
                .foregroundStyle(tool.output == nil ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(activityTitle(for: tool))
                    .lineLimit(2)
                Text(tool.output == nil ? "Running · \(tool.name)" : "Done · \(tool.name)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private var subagentTools: [AppModel.LiveTool] {
        model.liveTools.filter(isSubagentTool)
    }

    private var backgroundTools: [AppModel.LiveTool] {
        model.liveTools.filter { tool in
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

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    if model.canLoadOlderTranscript {
                        Button {
                            Task { await model.loadOlderTranscript() }
                        } label: {
                            HStack(spacing: 8) {
                                if model.isLoadingOlderTranscript {
                                    ProgressView().controlSize(.small)
                                    Text("Loading older messages…")
                                } else {
                                    Text("Load older messages")
                                }
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isLoadingOlderTranscript || model.isLoadingTranscript)
                    }
                    ForEach(model.transcriptGroups) { group in
                        Group {
                            switch group {
                            case .message(_, let message):
                                TranscriptMessageView(
                                    message: message,
                                    imageData: model.imageData,
                                    onQuote: { quote in
                                        draft += (draft.isEmpty ? "" : "\n\n") + quote + "\n\n"
                                    }
                                )
                            case .tools(_, let steps, let collapseSingle):
                                TranscriptToolRunView(steps: steps, collapseSingle: collapseSingle)
                            }
                        }
                        .id(group.id)
                    }
                    if model.isRunning {
                        LiveTranscriptResponseView(model: model)
                            .id("live")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: BottomPositionKey.self,
                                    value: geometry.frame(in: .named("transcriptScroll")).maxY
                                )
                            }
                        }
                }
                .frame(maxWidth: 860)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "transcriptScroll")
            .onAppear {
                guard model.selectedSessionID != nil else { return }
                isAtBottom = true
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: model.selectedSessionID) { _, sessionID in
                guard sessionID != nil else {
                    shouldScrollToLatestAfterLoad = false
                    return
                }
                if model.isLoadingTranscript {
                    shouldScrollToLatestAfterLoad = true
                } else {
                    isAtBottom = true
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: model.isLoadingTranscript) { wasLoading, isLoading in
                guard wasLoading, !isLoading, shouldScrollToLatestAfterLoad else { return }
                shouldScrollToLatestAfterLoad = false
                isAtBottom = true
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onPreferenceChange(BottomPositionKey.self) { bottomPosition in
                isAtBottom = bottomPosition <= transcriptViewportHeight + 24
            }
            .onChange(of: model.liveText) { _, _ in
                scrollToLatestIfNeeded(using: proxy)
            }
            .onChange(of: model.liveThinking) { _, _ in
                scrollToLatestIfNeeded(using: proxy)
            }
            .onChange(of: model.liveTools.count) { _, _ in
                scrollToLatestIfNeeded(using: proxy)
            }
            .onChange(of: outlineJump?.nonce) { _, _ in
                guard let groupID = outlineJump?.groupID else { return }
                withAnimation { proxy.scrollTo(groupID, anchor: .top) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    Button {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "chevron.down.2")
                            .font(.title3.weight(.semibold))
                            .frame(width: 42, height: 42)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Jump to latest")
                    .padding(20)
                }
            }
            .overlay {
                if model.isLoadingTranscript {
                    ProgressView().controlSize(.small)
                } else if model.messages.isEmpty, !model.isRunning {
                    ContentUnavailableView(
                        "No transcript",
                        systemImage: "text.bubble",
                        description: Text("This session only contains metadata; Claude Code did not save any messages.")
                    )
                }
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { transcriptViewportHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, height in
                            transcriptViewportHeight = height
                        }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !model.queuedPrompts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Queued · \(model.queuedPrompts.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !model.isRunning, let sessionID = model.selectedSessionID,
                           model.queuedPrompts.contains(where: {
                               $0.scheduledAt == nil && $0.dispatchStartedAt == nil
                           }) {
                            Button("Send next") { model.sendNextQueued(for: sessionID) }
                                .font(.caption)
                        }
                    }
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(model.queuedPrompts) { entry in
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.text.isEmpty ? "Image message" : entry.text)
                                            .lineLimit(2)
                                            .font(.callout)
                                        if !entry.attachments.isEmpty {
                                            Text("\(entry.attachments.count) image(s)")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        } else if entry.dispatchStartedAt != nil {
                                            Text("Delivery unconfirmed · take back to retry")
                                                .font(.caption2).foregroundStyle(.orange)
                                        } else if let scheduledAt = entry.scheduledAt {
                                            Text("Scheduled for \(scheduledAt.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    if model.isRunning && entry.scheduledAt == nil {
                                        Button("Steer") { model.steerQueuedPrompt(entry.id) }
                                            .font(.callout)
                                            .disabled(!model.canSteerQueuedPrompt || entry.dispatchStartedAt != nil)
                                            .help("Stop the current reply and send this message next")
                                    }
                                    Button {
                                        model.removeQueuedPrompt(entry.id)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.plain)
                                    .help("Remove from queue")
                                    .disabled(entry.dispatchStartedAt != nil
                                        && model.scheduledDispatchingSessionID == model.selectedSessionID)
                                    Menu {
                                        Button("Edit in composer", systemImage: "pencil") {
                                            guard let editable = model.takeQueuedPrompt(entry.id) else { return }
                                            let separator = draft.isEmpty || editable.text.isEmpty ? "" : "\n\n"
                                            draft += separator + editable.text
                                            model.pendingAttachments += editable.attachments
                                        }
                                        Divider()
                                        Button("Move up", systemImage: "arrow.up") {
                                            model.moveQueuedPrompt(entry.id, by: -1)
                                        }
                                        .disabled(!model.canMoveQueuedPrompt(entry.id, by: -1))
                                        Button("Move down", systemImage: "arrow.down") {
                                            model.moveQueuedPrompt(entry.id, by: 1)
                                        }
                                        .disabled(!model.canMoveQueuedPrompt(entry.id, by: 1))
                                    } label: {
                                        Image(systemName: "ellipsis")
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                    .help("Queue message actions")
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
            if !model.pendingAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(model.pendingAttachments) { attachment in
                            AttachmentThumbnail(
                                attachment: attachment,
                                data: model.imageData(for: attachment),
                                remove: { model.removeAttachment(attachment.id) },
                                moveLeft: { model.moveAttachment(attachment.id, by: -1) },
                                moveRight: { model.moveAttachment(attachment.id, by: 1) }
                            )
                        }
                    }
                }
                .frame(height: 64)
            }

            VStack(spacing: 8) {
                if !visibleSuggestions.isEmpty {
                    suggestionList
                }

                ComposerTextView(
                    text: $draft,
                    selection: $composerSelection,
                    onSend: submit,
                    onPasteImage: { model.attachImage(
                        data: $0, mediaType: "image/png", fileName: "Pasted image.png"
                    ) },
                    onPasteFiles: { $0.forEach(model.attachImage) },
                    suggestionsPresented: !visibleSuggestions.isEmpty,
                    onMoveSuggestion: moveSuggestion,
                    onAcceptSuggestion: acceptSelectedSuggestion,
                    onDismissSuggestions: dismissSuggestions
                )
                    .frame(minHeight: 48, maxHeight: 130)

                HStack {
                    Button { isImageImporterPresented = true } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("Attach image")

                    Menu {
                        Button("Send now") { pendingSchedule = nil }
                        Divider()
                        Button("In 5 minutes") { pendingSchedule = .minutes(5) }
                        Button("In 30 minutes") { pendingSchedule = .minutes(30) }
                        Button("In 1 hour") { pendingSchedule = .minutes(60) }
                        Button("In 4 hours") { pendingSchedule = .minutes(240) }
                        Divider()
                        Button("Choose time…") {
                            customScheduleDate = Date().addingTimeInterval(30 * 60)
                            isCustomSchedulePresented = true
                        }
                    } label: {
                        Image(systemName: pendingSchedule == nil ? "clock" : "clock.fill")
                            .foregroundStyle(pendingSchedule == nil ? Color.secondary : Color.blue)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(pendingSchedule.map {
                        "Scheduled for \($0.fireDate(from: Date()).formatted(date: .abbreviated, time: .shortened))"
                    } ?? "Schedule send")

                    permissionMenu
                    Spacer()
                    if model.selectedProvider?.kind == .codex {
                        codexEffortPicker
                    } else {
                        modelMenu
                        effortMenu
                    }
                    if model.isRunning {
                        Button(action: model.cancel) {
                            Image(systemName: "stop.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Stop current turn")
                    }
                    Button(action: submit) {
                        Image(systemName: model.isRunning ? "text.badge.plus" : "arrow.up")
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.blue, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(pendingSchedule == nil
                          ? (model.isRunning ? "Queue message" : "Send") : "Schedule message")
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && model.pendingAttachments.isEmpty)
                }
            }
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
        .frame(maxWidth: 860)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var modelMenu: some View {
        Menu {
            modelOptions
        } label: {
            Text(selectedModelName).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var permissionMenu: some View {
        Menu {
            if model.selectedProvider?.kind == .codex {
                codexPermissionOption(.manual, title: "Ask for approval")
                codexPermissionOption(.automatic, title: "Approve for me")
            } else if model.selectedProvider?.kind == .claudeCode
                || model.selectedProvider?.kind == .claudeCodeCompatible {
                ForEach(SessionRecord.ClaudePermissionMode.allCases, id: \.self) { mode in
                    Button {
                        model.updateClaudePermissionMode(mode)
                    } label: {
                        if selectedClaudePermissionMode == mode {
                            Label(claudePermissionLabel(mode), systemImage: "checkmark")
                        } else {
                            Text(claudePermissionLabel(mode))
                        }
                    }
                }
            } else {
                ForEach(PermissionRule.Effect.allCases, id: \.self) { effect in
                    permissionOption(effect)
                }
            }
        } label: {
            Label(selectedPermissionLabel, systemImage: permissionIcon)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Tool permission mode")
    }

    @ViewBuilder
    private var modelOptions: some View {
        if model.selectedProvider != nil {
            Button("Provider default") { model.updateModel(nil) }
            Divider()
            ForEach(availableModels, id: \.id) { candidate in
                Button(candidate.displayName) { model.updateModel(candidate.id) }
            }
            Divider()
            Button("Custom model ID…") {
                customModelID = model.selectedSession?.modelID?.rawValue ?? ""
                isCustomModelPresented = true
            }
        }
    }

    private func permissionOption(_ effect: PermissionRule.Effect) -> some View {
        Button {
            model.updatePermissionEffect(effect)
        } label: {
            if selectedPermissionEffect == effect {
                Label(permissionLabel(effect), systemImage: "checkmark")
            } else {
                Text(permissionLabel(effect))
            }
        }
    }

    private func codexPermissionOption(
        _ mode: SessionRecord.CodexApprovalMode,
        title: String
    ) -> some View {
        Button {
            model.updateCodexApprovalMode(mode)
        } label: {
            if selectedCodexApprovalMode == mode {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var selectedCodexApprovalMode: SessionRecord.CodexApprovalMode? {
        model.selectedSession?.codexApprovalMode
    }

    private var selectedPermissionLabel: String {
        if model.selectedProvider?.kind == .claudeCode
            || model.selectedProvider?.kind == .claudeCodeCompatible {
            return claudePermissionLabel(selectedClaudePermissionMode)
        }
        guard model.selectedProvider?.kind == .codex else {
            return permissionLabel(selectedPermissionEffect)
        }
        switch selectedCodexApprovalMode {
        case .manual: return "Ask for approval"
        case .automatic: return "Approve for me"
        case nil: return permissionLabel(selectedPermissionEffect)
        }
    }

    private var selectedPermissionEffect: PermissionRule.Effect {
        model.selectedSession?.permissionEffect ?? .ask
    }

    private var selectedClaudePermissionMode: SessionRecord.ClaudePermissionMode {
        if let mode = model.selectedSession?.claudePermissionMode { return mode }
        return switch selectedPermissionEffect {
        case .ask: .manual
        case .deny: .dontAsk
        case .allow: .bypassPermissions
        }
    }

    private func claudePermissionLabel(_ mode: SessionRecord.ClaudePermissionMode) -> String {
        switch mode {
        case .manual: "Manual"
        case .acceptEdits: "Auto accept edits"
        case .plan: "Plan"
        case .auto: "Auto"
        case .dontAsk: "Don't ask"
        case .bypassPermissions: "Bypass permissions"
        }
    }

    private var permissionIcon: String {
        if model.selectedProvider?.kind == .claudeCode
            || model.selectedProvider?.kind == .claudeCodeCompatible {
            return switch selectedClaudePermissionMode {
            case .manual: "hand.raised"
            case .acceptEdits: "pencil.line"
            case .plan: "list.bullet.clipboard"
            case .auto: "sparkles"
            case .dontAsk: "hand.raised.slash"
            case .bypassPermissions: "lock.open"
            }
        }
        if model.selectedProvider?.kind == .codex {
            switch selectedCodexApprovalMode {
            case .manual: return "hand.raised"
            case .automatic: return "shield.lefthalf.filled"
            case nil: break
            }
        }
        return switch selectedPermissionEffect {
        case .deny: "lock.fill"
        case .ask: "shield.lefthalf.filled"
        case .allow: "lock.open.fill"
        }
    }

    private func permissionLabel(_ effect: PermissionRule.Effect) -> String {
        switch (model.selectedProvider?.kind, effect) {
        case (.codex, .deny): "Read only"
        case (.codex, .ask): "Approve for me"
        case (.codex, .allow): "Full access"
        case (_, .deny): "Deny tools"
        case (_, .ask): "Ask"
        case (_, .allow): "Bypass permissions"
        }
    }

    private var suggestionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(visibleSuggestions.enumerated()), id: \.element.id) { index, item in
                        Button {
                            acceptSuggestion(item)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.kind == .skill ? "shippingbox" : "terminal")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .foregroundStyle(.primary)
                                    if !item.detail.isEmpty {
                                        Text(item.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                Text(item.source)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                index == selectedSuggestionIndex
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .onHover { hovering in
                            if hovering { selectedSuggestionIndex = index }
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 250)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .onChange(of: selectedSuggestionIndex) { _, index in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(index) }
            }
        }
    }

    private var completionContext: ComposerCompletionContext? {
        ComposerCompletionContext(text: draft, selection: composerSelection)
    }

    private var visibleSuggestions: [ComposerSuggestion] {
        guard let context = completionContext,
              context.fingerprint != dismissedCompletion else { return [] }
        let items = context.trigger == "@"
            ? model.sessions
                .filter { $0.id != model.selectedSessionID && $0.messageCount > 0 && $0.isArchived != true }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(100)
                .map { session in
                    ComposerSuggestion(
                        kind: .session,
                        name: session.title ?? "Untitled session",
                        detail: session.providerID.rawValue,
                        source: session.id.description
                    )
                }
            : composerItems
        return Array(items.filter { item in
            guard item.kind.trigger == context.trigger else { return false }
            return context.query.isEmpty
                || item.title.localizedCaseInsensitiveContains(context.query)
                || item.detail.localizedCaseInsensitiveContains(context.query)
        }.prefix(20))
    }

    private var composerCatalogID: String {
        "\(model.selectedProvider?.kind.rawValue ?? "none"):\(model.selectedProject?.rootPath ?? "")"
    }

    private var permissionDialogPresented: Binding<Bool> {
        Binding(
            get: { model.pendingPermissionRequest != nil },
            set: { if !$0, model.pendingPermissionRequest != nil { model.answerPermission(.deny) } }
        )
    }

    private var permissionRequestDescription: String {
        guard let request = model.pendingPermissionRequest else { return "" }
        return [model.pendingPermissionSessionTitle, request.summary, request.primaryArgument]
            .compactMap { $0 }.joined(separator: "\n\n")
    }

    private func moveSuggestion(_ offset: Int) {
        let count = visibleSuggestions.count
        guard count > 0 else { return }
        selectedSuggestionIndex = (selectedSuggestionIndex + offset + count) % count
    }

    private func acceptSelectedSuggestion() {
        let suggestions = visibleSuggestions
        guard !suggestions.isEmpty else { return }
        acceptSuggestion(suggestions[min(selectedSuggestionIndex, suggestions.count - 1)])
    }

    private func acceptSuggestion(_ suggestion: ComposerSuggestion) {
        guard let context = completionContext else { return }
        let mutable = NSMutableString(string: draft)
        let replacement = suggestion.kind == .session
            ? "See session \(String(reflecting: suggestion.name)) [[session:\(suggestion.source)]] for context. "
            : suggestion.title + " "
        mutable.replaceCharacters(in: context.range, with: replacement)
        draft = mutable as String
        composerSelection = NSRange(
            location: context.range.location + (replacement as NSString).length,
            length: 0
        )
        dismissedCompletion = nil
    }

    private func dismissSuggestions() {
        dismissedCompletion = completionContext?.fingerprint
    }

    private var effortMenu: some View {
        Menu {
            Button("Auto") { model.updateEffort(nil) }
            ForEach(supportedEfforts, id: \.self) { effort in
                Button(effort.displayName) { model.updateEffort(effort) }
            }
        } label: {
            Text(model.selectedSession?.effort?.displayName ?? "Auto")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var codexEffortPicker: some View {
        Button {
            isCodexEffortPresented.toggle()
            isCodexModelListPresented = false
        } label: {
            HStack(spacing: 7) {
                Text(selectedCodexEffort?.displayName ?? "Select effort")
                Image(systemName: "chevron.down").font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var codexEffortPanel: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Button {
                    model.updateCodexFastMode(!(model.selectedSession?.codexFastMode ?? false))
                } label: {
                    Image(systemName: "bolt")
                        .font(.system(size: 14))
                        .foregroundStyle(model.selectedSession?.codexFastMode == true ? Color.accentColor : Color.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(model.selectedSession?.codexFastMode == true
                    ? "Turn off Codex Fast mode" : "Turn on Codex Fast mode (uses more credits)")
                Spacer()
                VStack(spacing: 2) {
                    Text(selectedCodexEffort?.displayName ?? "Select effort")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tint)
                    Button {
                        isCodexModelListPresented.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedModelName).lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 10))
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Color.clear.frame(width: 26, height: 26)
            }
            if isCodexModelListPresented {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        codexModelRow("Provider default", id: nil)
                        ForEach(availableModels, id: \.id) { candidate in
                            codexModelRow(candidate.displayName, id: candidate.id)
                        }
                        Button("Custom model ID…") {
                            customModelID = model.selectedSession?.modelID?.rawValue ?? ""
                            isCustomModelPresented = true
                            isCodexEffortPresented = false
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                }
                .frame(maxHeight: 220)
            } else if supportedEfforts.count > 1 {
                codexEffortTrack
            } else {
                Text("Choose a model to adjust reasoning effort")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 286)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 19))
        .overlay {
            RoundedRectangle(cornerRadius: 19)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
    }

    private func codexModelRow(_ title: String, id: ModelID?) -> some View {
        Button {
            model.updateModel(id)
            isCodexModelListPresented = false
        } label: {
            HStack {
                Text(title)
                Spacer()
                if model.selectedSession?.modelID == id {
                    Image(systemName: "checkmark")
                }
            }
            .font(.system(size: 12))
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var codexEffortTrack: some View {
        GeometryReader { geometry in
            let diameter: CGFloat = 28
            let travel = geometry.size.width - diameter
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .controlColor))
                    .frame(height: diameter)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(
                        width: diameter / 2 + travel * CGFloat(codexEffortIndex.wrappedValue)
                            / CGFloat(supportedEfforts.count - 1),
                        height: diameter
                    )
                ForEach(supportedEfforts.indices, id: \.self) { index in
                    Circle()
                        .fill(index < Int(codexEffortIndex.wrappedValue.rounded())
                            ? Color.white.opacity(0.55) : Color.secondary.opacity(0.6))
                        .frame(width: 4, height: 4)
                        .offset(x: diameter / 2 - 2 + travel * CGFloat(index) / CGFloat(supportedEfforts.count - 1))
                }
                Circle()
                    .fill(.white)
                    .frame(width: diameter, height: diameter)
                    .offset(x: travel * CGFloat(codexEffortIndex.wrappedValue) / CGFloat(supportedEfforts.count - 1))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let fraction = min(max((value.location.x - diameter / 2) / travel, 0), 1)
                codexEffortIndex.wrappedValue = Double(fraction) * Double(supportedEfforts.count - 1)
            })
        }
        .frame(height: 28)
        .accessibilityLabel("Reasoning effort")
    }

    private var selectedCodexEffort: ReasoningEffort? {
        if let effort = model.selectedSession?.effort { return effort }
        guard let id = model.selectedSession?.modelID else { return nil }
        return modelDefaultEfforts[id]
    }

    private var codexEffortIndex: Binding<Double> {
        Binding(
            get: {
                Double(supportedEfforts.firstIndex(of: selectedCodexEffort ?? .medium) ?? 0)
            },
            set: { index in
                let position = min(max(Int(index.rounded()), 0), supportedEfforts.count - 1)
                guard supportedEfforts.indices.contains(position) else { return }
                model.updateEffort(supportedEfforts[position])
            }
        )
    }

    private var selectedModelName: String {
        guard let id = model.selectedSession?.modelID else { return "Default model" }
        return availableModels.first(where: { $0.id == id })?.displayName ?? id.rawValue
    }

    private var supportedEfforts: [ReasoningEffort] {
        guard let id = model.selectedSession?.modelID else { return [] }
        return availableModels.first(where: { $0.id == id })?.supportedEfforts ?? []
    }

    private var modelCatalogID: String {
        "\(model.selectedProvider?.id.rawValue ?? "none"):\(model.selectedSession?.backendID?.rawValue ?? "local")"
    }

    private func submit() {
        let prompt = draft
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.pendingAttachments.isEmpty else { return }
        if let pendingSchedule {
            if model.enqueueDraft(prompt, scheduledAt: pendingSchedule.fireDate(from: Date())) {
                draft = ""
                self.pendingSchedule = nil
            }
            return
        }
        if model.isRunning {
            if model.enqueueDraft(prompt) { draft = "" }
            return
        }
        draft = ""
        model.send(prompt)
    }

    private func restoreComposerDraft(for sessionID: SessionID?) {
        let saved = sessionID.flatMap(model.loadComposerDraft)
        draft = saved?.text ?? ""
        model.pendingAttachments = saved?.attachments ?? []
    }

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        guard let sessionID = model.selectedSessionID else { return }
        let text = draft
        let attachments = model.pendingAttachments
        draftSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, model.selectedSessionID == sessionID else { return }
            model.saveComposerDraft(text, attachments: attachments, for: sessionID)
        }
    }

    private func scrollToLatestIfNeeded(using proxy: ScrollViewProxy) {
        guard isAtBottom else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }
}

private struct BottomPositionKey: PreferenceKey {
    static let defaultValue = CGFloat.infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum ProviderModelDiscovery {
    struct Catalog: Sendable {
        var models: [ModelDescriptor] = []
        var defaultEfforts: [ModelID: ReasoningEffort] = [:]
    }

    private struct Cache: Decodable {
        struct Entry: Decodable {
            struct Level: Decodable { let effort: String }
            let slug: String
            let displayName: String
            let visibility: String
            let supportedReasoningLevels: [Level]
            let defaultReasoningLevel: String?
            let contextWindow: Int?

            enum CodingKeys: String, CodingKey {
                case slug, visibility
                case displayName = "display_name"
                case supportedReasoningLevels = "supported_reasoning_levels"
                case defaultReasoningLevel = "default_reasoning_level"
                case contextWindow = "context_window"
            }
        }
        let models: [Entry]
    }

    static func models(for provider: AgentProviderDescriptor?, backendID: String) -> Catalog {
        guard let provider else { return Catalog() }
        if let configured = provider.models { return Catalog(models: configured) }
        switch provider.kind {
        case .codex:
            guard backendID == "local" else { return Catalog() }
            let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/models_cache.json")
            guard let data = try? Data(contentsOf: path),
                  let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return Catalog() }
            let entries = cache.models.filter { $0.visibility == "list" }
            let defaults = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
                entry.defaultReasoningLevel.flatMap(ReasoningEffort.init(rawValue:))
                    .map { (ModelID(entry.slug), $0) }
            })
            let models = entries.map { entry in
                ModelDescriptor(
                    id: ModelID(entry.slug),
                    displayName: entry.displayName,
                    supportedEfforts: entry.supportedReasoningLevels.compactMap {
                        ReasoningEffort(rawValue: $0.effort)
                    },
                    contextWindowTokens: entry.contextWindow
                )
            }
            return Catalog(models: models, defaultEfforts: defaults)
        case .claudeCode:
            return Catalog(models: ModelCatalog.claudeCodeSnapshot.models)
        case .claudeCodeCompatible:
            return Catalog()
        }
    }
}

private struct AttachmentThumbnail: View {
    let attachment: ImageAttachment
    let data: Data?
    let remove: () -> Void
    let moveLeft: () -> Void
    let moveRight: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 58, height: 58).clipped()
            }
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Move left", action: moveLeft)
            Button("Move right", action: moveRight)
            Button("Remove", role: .destructive, action: remove)
        }
    }
}

private struct ComposerCompletionContext {
    let trigger: Character
    let query: String
    let range: NSRange

    init?(text: String, selection: NSRange) {
        let nsText = text as NSString
        guard selection.length == 0, selection.location <= nsText.length else { return nil }
        let separators = CharacterSet.whitespacesAndNewlines
        var start = selection.location
        while start > 0 {
            let scalar = UnicodeScalar(nsText.character(at: start - 1))
            if scalar.map(separators.contains) == true { break }
            start -= 1
        }
        let tokenRange = NSRange(location: start, length: selection.location - start)
        let token = nsText.substring(with: tokenRange)
        guard let first = token.first, first == "$" || first == "/" || first == "@" else { return nil }
        trigger = first
        query = String(token.dropFirst())
        range = tokenRange
    }

    var fingerprint: String { "\(range.location):\(trigger)\(query)" }
}

private struct ComposerSuggestion: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case skill
        case command
        case session

        var trigger: Character {
            switch self {
            case .skill: "$"
            case .command: "/"
            case .session: "@"
            }
        }
    }

    let kind: Kind
    let name: String
    let detail: String
    let source: String

    var id: String { "\(kind.rawValue):\(name):\(source)" }
    var title: String { "\(kind.trigger)\(name)" }
}

private enum ComposerCatalog {
    static func load(
        projectPath: String?,
        providerKind: AgentProviderDescriptor.Kind?
    ) async -> [ComposerSuggestion] {
        await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            var items = builtInCommands(for: providerKind)
            var skillRoots = [
                (home.appendingPathComponent(".codex/skills"), "Local file"),
                (home.appendingPathComponent(".agents/skills"), "Local file"),
            ]
            skillRoots += projectRoots(projectPath, component: ".codex/skills", source: "Project")
            skillRoots += projectRoots(projectPath, component: ".agents/skills", source: "Project")
            items += markdownItems(
                roots: skillRoots,
                fileName: "SKILL.md",
                kind: .skill
            )
            var commandRoots = [(home.appendingPathComponent(".claude/commands"), "Local command")]
            commandRoots += projectRoots(
                projectPath,
                component: ".claude/commands",
                source: "Project command"
            )
            items += markdownItems(
                roots: commandRoots,
                fileName: nil,
                kind: .command
            )
            var seen: Set<String> = []
            return items
                .filter { seen.insert("\($0.kind.rawValue):\($0.name.lowercased())").inserted }
                .sorted {
                    if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
        }.value
    }

    private static func projectRoots(
        _ projectPath: String?,
        component: String,
        source: String
    ) -> [(URL, String)] {
        guard let projectPath else { return [] }
        return [(URL(fileURLWithPath: projectPath).appendingPathComponent(component), source)]
    }

    private static func markdownItems(
        roots: [(URL, String)],
        fileName: String?,
        kind: ComposerSuggestion.Kind
    ) -> [ComposerSuggestion] {
        let manager = FileManager.default
        return roots.flatMap { root, source -> [ComposerSuggestion] in
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            ) else { return [] }
            return enumerator.compactMap { value in
                guard let url = value as? URL,
                      url.pathExtension.lowercased() == "md",
                      fileName == nil || url.lastPathComponent == fileName else { return nil }
                let fallbackName = fileName == nil
                    ? url.deletingPathExtension().lastPathComponent
                    : url.deletingLastPathComponent().lastPathComponent
                let metadata = markdownMetadata(at: url, fallbackName: fallbackName)
                return ComposerSuggestion(
                    kind: kind,
                    name: metadata.name,
                    detail: metadata.description,
                    source: url.path.contains("/.system/") ? "Built-in" : source
                )
            }
        }
    }

    private static func markdownMetadata(at url: URL, fallbackName: String) -> (name: String, description: String) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: data.prefix(32_768), encoding: .utf8) else {
            return (fallbackName, "")
        }
        let lines = text.components(separatedBy: .newlines)
        let name = frontMatterValue("name", lines: lines) ?? fallbackName
        let description = frontMatterValue("description", lines: lines)
            ?? lines.first(where: { !$0.isEmpty && !$0.hasPrefix("#") && $0 != "---" })
            ?? ""
        return (name, description)
    }

    private static func frontMatterValue(_ key: String, lines: [String]) -> String? {
        let prefix = "\(key):"
        guard let line = lines.prefix(80).first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return line.dropFirst(prefix.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \\\"'"))
    }

    private static func builtInCommands(
        for providerKind: AgentProviderDescriptor.Kind?
    ) -> [ComposerSuggestion] {
        let common = [
            ("compact", "Compact conversation context"),
            ("model", "Choose the active model"),
            ("permissions", "Change tool permission mode"),
            ("status", "Show session and environment status"),
        ]
        let providerCommands: [(String, String)]
        switch providerKind {
        case .codex:
            providerCommands = [
                ("diff", "Review working tree changes"),
                ("review", "Review the current implementation"),
                ("new", "Start a new conversation"),
            ]
        case .claudeCode, .claudeCodeCompatible:
            providerCommands = [
                ("context", "Inspect context usage"),
                ("cost", "Show token usage and cost"),
                ("doctor", "Check Claude Code installation"),
                ("help", "Show available commands"),
                ("init", "Create project instructions"),
                ("memory", "Edit project memory"),
                ("review", "Review the current implementation"),
            ]
        case nil:
            providerCommands = []
        }
        return (common + providerCommands).map {
            ComposerSuggestion(kind: .command, name: $0.0, detail: $0.1, source: "Built-in")
        }
    }
}
