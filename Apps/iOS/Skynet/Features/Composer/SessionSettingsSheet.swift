import SwiftUI

/// Session configuration editor: model, reasoning effort, and permission
/// mode. Changes apply immediately through `onApply`.
struct SessionSettingsSheet: View {
    let session: AgentSession
    let availableModels: [AgentModel]
    let onApply: (AgentConfiguration) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentConfiguration

    init(
        session: AgentSession,
        availableModels: [AgentModel],
        onApply: @escaping (AgentConfiguration) -> Void
    ) {
        self.session = session
        self.availableModels = availableModels
        self.onApply = onApply
        _draft = State(initialValue: session.configuration)
    }

    private var models: [AgentModel] {
        availableModels.isEmpty ? AgentModel.defaultCatalog : availableModels
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Model", selection: $draft.model) {
                        ForEach(models) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.inline)
                    .accessibilityIdentifier(A11yID.Settings.modelPicker)
                } header: {
                    Text("Model")
                } footer: {
                    Text(selectedModelSummary)
                }

                Section {
                    Picker("Reasoning Effort", selection: $draft.effort) {
                        ForEach(ReasoningEffort.allCases) { effort in
                            Text(effort.displayName).tag(effort)
                        }
                    }
                    .pickerStyle(.inline)
                    .disabled(!draft.model.supportsEffort)
                    .accessibilityIdentifier(A11yID.Settings.effortPicker)
                } header: {
                    Text("Reasoning Effort")
                } footer: {
                    Text(
                        draft.model.supportsEffort
                            ? draft.effort.summary
                            : "\(draft.model.displayName) manages its own reasoning depth."
                    )
                }

                Section {
                    Picker("Permissions", selection: $draft.permissions) {
                        ForEach(PermissionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .accessibilityIdentifier(A11yID.Settings.permissionPicker)
                } header: {
                    Text("Permissions")
                } footer: {
                    if draft.permissions == .autonomous {
                        Label(
                            "The agent will run commands and edit files without asking. Make sure you trust the task.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(Theme.warning)
                    } else {
                        Text(draft.permissions.summary)
                    }
                }
            }
            .navigationTitle("Session Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onApply(draft)
                        dismiss()
                    }
                    .accessibilityIdentifier(A11yID.Settings.doneButton)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier(A11yID.Settings.sheet)
    }

    private var selectedModelSummary: String {
        if let model = models.first(where: { $0 == draft.model }) {
            return model.summary
        }
        return draft.model.summary
    }
}

#Preview("Settings sheet") {
    SessionSettingsSheet(
        session: PreviewData.runningSession,
        availableModels: AgentModel.defaultCatalog
    ) { _ in }
}
