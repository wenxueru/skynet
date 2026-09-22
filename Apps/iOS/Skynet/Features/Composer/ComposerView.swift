import SwiftUI

/// The polished bottom composer: configuration controls (model, effort,
/// permissions), photo/camera attachment, a self-sizing input field, and a
/// send button that becomes "add to queue" whenever the link or the running
/// turn blocks immediate delivery.
struct ComposerView: View {
    @Bindable var model: ComposerViewModel
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            AttachmentStripView(
                attachments: model.attachments,
                onRemove: { id in model.removeAttachment(id: id) }
            )

            controlsRow

            inputRow
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.xs)
        .padding(.bottom, Theme.Spacing.xs)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider().opacity(0.4)
        }
        .sheet(isPresented: $model.isCameraPresented) {
            CameraImagePicker { attachment in
                _ = model.attach(attachment)
            }
            .ignoresSafeArea()
        }
        .onChange(of: model.isFocused) { _, shouldFocus in
            isInputFocused = shouldFocus
        }
        .onChange(of: isInputFocused) { _, focused in
            model.isFocused = focused
        }
        .accessibilityIdentifier(A11yID.Composer.root)
    }

    // MARK: - Controls

    private var controlsRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            modelMenu
            effortMenu
            permissionMenu

            Spacer(minLength: Theme.Spacing.sm)

            PhotoAttachmentPicker(
                canAttachMore: model.canAttachMore,
                onAttach: { attachment in
                    _ = model.attach(attachment)
                }
            )

            if CameraImagePicker.isCameraAvailable {
                Button {
                    model.isCameraPresented = true
                } label: {
                    Image(systemName: "camera")
                        .font(.body)
                        .frame(width: 34, height: 34)
                }
                .disabled(!model.canAttachMore)
                .accessibilityLabel("Take a photo")
                .accessibilityIdentifier(A11yID.Composer.attachCameraButton)
            }
        }
    }

    private var modelMenu: some View {
        Menu {
            Picker(
                "Model",
                selection: Binding(
                    get: { model.currentConfiguration.model },
                    set: { newModel in
                        model.updateConfiguration { configuration in
                            configuration.model = newModel
                        }
                    }
                )
            ) {
                ForEach(model.state.availableModels) { candidate in
                    Text(candidate.displayName).tag(candidate)
                }
            }
        } label: {
            controlLabel(
                icon: "cpu",
                text: model.currentConfiguration.model.displayName
            )
        }
        .accessibilityIdentifier(A11yID.Composer.modelButton)
        .accessibilityLabel("Model: \(model.currentConfiguration.model.displayName)")
    }

    private var effortMenu: some View {
        let supportsEffort = model.currentConfiguration.model.supportsEffort
        return Menu {
            Picker(
                "Reasoning Effort",
                selection: Binding(
                    get: { model.currentConfiguration.effort },
                    set: { newEffort in
                        model.updateConfiguration { configuration in
                            configuration.effort = newEffort
                        }
                    }
                )
            ) {
                ForEach(ReasoningEffort.allCases) { effort in
                    Text(effort.displayName).tag(effort)
                }
            }
        } label: {
            controlLabel(
                icon: "gauge.with.needle",
                text: supportsEffort
                    ? model.currentConfiguration.effort.displayName
                    : "Auto"
            )
        }
        .disabled(!supportsEffort)
        .accessibilityIdentifier(A11yID.Composer.effortButton)
        .accessibilityLabel("Reasoning effort: \(model.currentConfiguration.effort.displayName)")
    }

    private var permissionMenu: some View {
        Menu {
            Picker(
                "Permissions",
                selection: Binding(
                    get: { model.currentConfiguration.permissions },
                    set: { newMode in
                        model.updateConfiguration { configuration in
                            configuration.permissions = newMode
                        }
                    }
                )
            ) {
                ForEach(PermissionMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        } label: {
            controlLabel(
                icon: "lock.shield",
                text: model.currentConfiguration.permissions.displayName
            )
        }
        .accessibilityIdentifier(A11yID.Composer.permissionButton)
        .accessibilityLabel("Permissions: \(model.currentConfiguration.permissions.displayName)")
    }

    private func controlLabel(icon: String, text: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .contentShape(Capsule())
    }

    // MARK: - Input

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
            TextField(
                "Message the agent",
                text: $model.draftText,
                axis: .vertical
            )
            .lineLimit(1...6)
            .padding(Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .focused($isInputFocused)
            .submitLabel(.send)
            .onSubmit {
                model.performPrimaryAction()
            }
            .accessibilityIdentifier(A11yID.Composer.textField)

            sendButton
        }
    }

    private var sendButton: some View {
        Button {
            model.performPrimaryAction()
        } label: {
            Image(systemName: model.sendButtonImage)
                .font(.title2)
                .foregroundStyle(sendButtonTint)
                .frame(width: 34, height: 34)
                .overlay(alignment: .topTrailing) {
                    if model.sendAction == .queue {
                        Image(systemName: "tray.full.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.warning)
                            .offset(x: 8, y: -4)
                            .accessibilityIdentifier(A11yID.Composer.queueIndicator)
                    }
                }
        }
        .disabled(model.sendAction == .disabled)
        .accessibilityIdentifier(A11yID.Composer.sendButton)
        .accessibilityLabel(model.sendButtonLabel)
        .animation(.easeInOut(duration: 0.15), value: model.sendAction)
    }

    private var sendButtonTint: Color {
        switch model.sendAction {
        case .send: return Theme.accent
        case .queue: return Theme.warning
        case .disabled: return Color.secondary
        }
    }
}

// MARK: - Previews

#Preview("Composer") {
    ComposerView(model: ComposerViewModel(state: PreviewSessionState()))
        .padding(.bottom, 12)
}

/// Minimal `ComposerStateProviding` for previews of the composer in
/// isolation. (Preview-only; the real conformer is `SessionViewModel`.)
@MainActor
private final class PreviewSessionState: ComposerStateProviding {
    var currentTurnState: TurnState = .idle
    var currentConnectionState: ConnectionState = .connected
    var currentConfiguration: AgentConfiguration = .standard
    var queuedPromptCount: Int = 2
    var queuedPrompts: [QueuedPrompt] = [
        QueuedPrompt(payload: PromptPayload(text: "Run the tests again"), reason: .turnBusy),
        QueuedPrompt(payload: PromptPayload(text: "Then update the changelog"), reason: .offline),
    ]
    var isQueueFlushing: Bool = false
    var availableModels: [AgentModel] = AgentModel.defaultCatalog

    func composerDidRequestSend(_ payload: PromptPayload) {}
    func composerDidRequestQueue(_ payload: PromptPayload) {}
    func composerDidChangeConfiguration(_ configuration: AgentConfiguration) {}
    func composerDidRequestSendQueuedPrompt(id: UUID) {}
    func composerDidRequestRemoveQueuedPrompt(id: UUID) {}
}
