import SwiftUI

/// Full queue review: every held prompt with its hold reason, plus
/// per-prompt "send now" and "remove".
struct QueuedPromptsSheet: View {
    let state: any ComposerStateProviding
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if state.queuedPrompts.isEmpty {
                    EmptyStateView(
                        systemImage: "tray",
                        title: "Nothing queued",
                        message: "Prompts you queue land here until the connection and turn allow sending."
                    )
                } else {
                    List {
                        ForEach(state.queuedPrompts) { prompt in
                            row(prompt)
                        }

                        Section {
                            Text(
                                "Queued prompts send automatically, in order, as soon as the Mac is reachable and the current turn finishes."
                            )
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Queued Prompts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier(A11yID.Composer.queuedSheet)
    }

    private func row(_ prompt: QueuedPrompt) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(prompt.payload.text)
                .font(.subheadline)
                .lineLimit(3)

            HStack(spacing: Theme.Spacing.sm) {
                BadgeView(reasonTitle(for: prompt), tint: Theme.warning)
                Spacer()
                Button {
                    state.composerDidRequestSendQueuedPrompt(id: prompt.id)
                } label: {
                    Label("Send Now", systemImage: "paperplane")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(A11yID.Composer.queuedRowSendNow(prompt.id))

                Button(role: .destructive) {
                    state.composerDidRequestRemoveQueuedPrompt(id: prompt.id)
                } label: {
                    Label("Remove", systemImage: "trash")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(A11yID.Composer.queuedRemove(prompt.id))
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityIdentifier(A11yID.Composer.queuedRow(prompt.id))
    }

    private func reasonTitle(for prompt: QueuedPrompt) -> String {
        switch prompt.reason {
        case .offline: return "Waiting for connection"
        case .turnBusy: return "Waiting for turn"
        case .userRequested: return "You queued it"
        }
    }
}

#Preview("Queue sheet") {
    QueuedPromptsSheet(state: PreviewQueueSheetState(), onClose: {})
}

@MainActor
private final class PreviewQueueSheetState: ComposerStateProviding {
    var currentTurnState: TurnState = .running
    var currentConnectionState: ConnectionState = .connected
    var currentConfiguration: AgentConfiguration = .standard
    var queuedPromptCount: Int { queuedPrompts.count }
    var queuedPrompts: [QueuedPrompt] = [
        QueuedPrompt(payload: PromptPayload(text: "Run the tests again after the fix lands"), reason: .turnBusy),
        QueuedPrompt(payload: PromptPayload(text: "Then update the changelog"), reason: .offline),
        QueuedPrompt(
            payload: PromptPayload(text: "Also review the open PRs", attachments: [PreviewData.attachment()]),
            reason: .userRequested
        ),
    ]
    var isQueueFlushing: Bool = false
    var availableModels: [AgentModel] = AgentModel.defaultCatalog

    func composerDidRequestSend(_ payload: PromptPayload) {}
    func composerDidRequestQueue(_ payload: PromptPayload) {}
    func composerDidChangeConfiguration(_ configuration: AgentConfiguration) {}
    func composerDidRequestSendQueuedPrompt(id: UUID) {}
    func composerDidRequestRemoveQueuedPrompt(id: UUID) {}
}
