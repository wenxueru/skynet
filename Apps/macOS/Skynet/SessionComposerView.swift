import AppKit
import SkynetCore
import SwiftUI
import UniformTypeIdentifiers

/// Owns draft persistence, submission and composer controls. The content slot
/// keeps the model picker above the entire conversation, including its header.
struct SessionComposerView<Content: View>: View {
    @Bindable var model: AppModel
    @Binding var draft: String
    @ViewBuilder var content: Content
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var isImageImporterPresented = false
    @State private var composerSelection = NSRange(location: 0, length: 0)
    @State private var composerItems: [ComposerSuggestion] = []
    @State private var selectedSuggestionIndex = 0
    @State private var dismissedCompletion: String?
    @State private var availableModels: [ModelDescriptor] = []
    @State private var modelDiscoveryError: String?
    @State private var modelCatalogRevision = 0
    @State private var modelDefaultEfforts: [ModelID: ReasoningEffort] = [:]
    @State private var isCustomModelPresented = false
    @State private var customModelID = ""
    @State private var isCodexEffortPresented = false
    @State private var isCodexModelListPresented = false
    @State private var isCustomSchedulePresented = false
    @State private var customScheduleDate = Date().addingTimeInterval(30 * 60)
    @State private var pendingSchedule: PendingSchedule?

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

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                content
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
            restoreComposerDraft(for: model.selectedSessionID)
        }
        .onChange(of: model.selectedSessionID) { oldID, newID in
            draftSaveTask?.cancel()
            if let oldID, model.sessions.contains(where: { $0.id == oldID }) {
                model.saveComposerDraft(draft, attachments: model.pendingAttachments, for: oldID)
            }
            restoreComposerDraft(for: newID)
            pendingSchedule = nil
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
            guard let session = model.selectedSession else { return }
            availableModels = []
            modelDefaultEfforts = [:]
            modelDiscoveryError = nil
            let catalog = await ProviderModelDiscovery.models(
                for: provider, backend: model.executionBackend(for: session),
                workingDirectory: session.workingDirectory)
            guard !Task.isCancelled else { return }
            availableModels = catalog.models
            modelDefaultEfforts = catalog.defaultEfforts
            modelDiscoveryError = catalog.error
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
        .fileImporter(
            isPresented: $isImageImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                urls.forEach(model.attachImage)
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

    private var composer: some View {
        let suggestions = visibleSuggestions
        return VStack(spacing: 8) {
            if !model.queuedPrompts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Queued · \(model.queuedPrompts.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !model.shouldQueueComposerSubmission, let sessionID = model.selectedSessionID,
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
                                            let isSending = model.scheduledDispatchingSessionID == model.selectedSessionID
                                            Text(isSending ? "Sending…" : "Delivery unconfirmed · take back to retry")
                                                .font(.caption2)
                                                .foregroundStyle(isSending ? Color.secondary : Color.orange)
                                        } else if let scheduledAt = entry.scheduledAt {
                                            Text("Scheduled for \(scheduledAt.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    if model.isSelectedSessionRunning && entry.scheduledAt == nil {
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
                    .frame(height: min(180, CGFloat(model.queuedPrompts.count) * 72))
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
                if !suggestions.isEmpty {
                    suggestionList(suggestions)
                }

                ComposerTextView(
                    text: $draft,
                    selection: $composerSelection,
                    onSend: submit,
                    onPasteImage: { model.attachImage(
                        data: $0, mediaType: "image/png", fileName: "Pasted image.png"
                    ) },
                    onPasteFiles: { $0.forEach(model.attachImage) },
                    suggestionsPresented: !suggestions.isEmpty,
                    onMoveSuggestion: moveSuggestion,
                    onAcceptSuggestion: acceptSelectedSuggestion,
                    onDismissSuggestions: dismissSuggestions
                )
                    .id(model.selectedSessionID)
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
                    if model.canStopSelectedSession {
                        Button(action: model.cancel) {
                            Image(systemName: "stop.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Stop current turn")
                    }
                    Button(action: submit) {
                        Image(systemName: model.shouldQueueComposerSubmission ? "text.badge.plus" : "arrow.up")
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.blue, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(pendingSchedule == nil
                          ? (model.shouldQueueComposerSubmission ? "Queue message" : "Send") : "Schedule message")
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
                        Text((selectedClaudePermissionMode == mode ? "✓ " : "") + claudePermissionLabel(mode))
                    }
                }
            } else {
                ForEach(PermissionRule.Effect.allCases, id: \.self) { effect in
                    permissionOption(effect)
                }
            }
        } label: {
            Label(selectedPermissionLabel, systemImage: permissionIcon)
                .accessibilityLabel(selectedPermissionLabel)
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
            if let modelDiscoveryError {
                Text(modelDiscoveryError).disabled(true)
                Button("Retry model discovery") { modelCatalogRevision += 1 }
            }
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
            Text((selectedPermissionEffect == effect ? "✓ " : "") + permissionLabel(effect))
        }
    }

    private func codexPermissionOption(
        _ mode: SessionRecord.CodexApprovalMode,
        title: String
    ) -> some View {
        Button {
            model.updateCodexApprovalMode(mode)
        } label: {
            Text((selectedCodexApprovalMode == mode ? "✓ " : "") + title)
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

    private func suggestionList(_ suggestions: [ComposerSuggestion]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, item in
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
                        if let modelDiscoveryError {
                            Text(modelDiscoveryError).font(.caption).foregroundStyle(.secondary)
                            Button("Retry model discovery") { modelCatalogRevision += 1 }
                        }
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

    private struct ModelCatalogContext: Equatable {
        let provider: AgentProviderDescriptor?
        let backendID: BackendID?
        let workingDirectory: String?
        let revision: Int
    }

    private var modelCatalogID: ModelCatalogContext {
        ModelCatalogContext(provider: model.selectedProvider,
                            backendID: model.selectedSession?.backendID,
                            workingDirectory: model.selectedSession?.workingDirectory,
                            revision: modelCatalogRevision)
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
        if model.shouldQueueComposerSubmission {
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
