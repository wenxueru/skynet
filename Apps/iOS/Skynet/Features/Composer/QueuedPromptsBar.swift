import SwiftUI

/// Compact bar above the composer showing how many prompts are queued and
/// why they're held. Tapping opens the queue sheet.
struct QueuedPromptsBar: View {
    let state: any ComposerStateProviding
    let onOpenQueue: () -> Void

    var body: some View {
        if state.queuedPromptCount > 0 {
            VStack(spacing: 0) {
                Divider()
                Button(action: onOpenQueue) {
                    HStack(spacing: Theme.Spacing.sm) {
                        if state.isQueueFlushing {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "tray.full")
                                .font(.footnote)
                                .foregroundStyle(Theme.warning)
                        }

                        Text(
                            state.isQueueFlushing
                                ? "Sending queued prompts…"
                                : "\(state.queuedPromptCount) prompt\(state.queuedPromptCount == 1 ? "" : "s") queued"
                        )
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier(A11yID.Composer.queuedCount)

                        Spacer(minLength: Theme.Spacing.md)

                        Text("Review")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Theme.warning.opacity(0.1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11yID.Composer.queuedListButton)
                .accessibilityLabel("\(state.queuedPromptCount) prompts queued. Opens the queue.")
                .accessibilityAddTraits(.isButton)
            }
            .accessibilityIdentifier(A11yID.Composer.queuedBar)
        }
    }
}

#Preview("Queue bar") {
    VStack {
        Spacer()
        QueuedPromptsBar(
            state: PreviewQueueState(),
            onOpenQueue: {}
        )
    }
}

@MainActor
private final class PreviewQueueState: ComposerStateProviding {
    var currentTurnState: TurnState = .running
    var currentConnectionState: ConnectionState = .connected
    var currentConfiguration: AgentConfiguration = .standard
    var queuedPromptCount: Int { queuedPrompts.count }
    var queuedPrompts: [QueuedPrompt] = [
        QueuedPrompt(payload: PromptPayload(text: "Run the tests again"), reason: .turnBusy),
    ]
    var isQueueFlushing: Bool = false
    var availableModels: [AgentModel] = AgentModel.defaultCatalog

    func composerDidRequestSend(_ payload: PromptPayload) {}
    func composerDidRequestQueue(_ payload: PromptPayload) {}
    func composerDidChangeConfiguration(_ configuration: AgentConfiguration) {}
    func composerDidRequestSendQueuedPrompt(id: UUID) {}
    func composerDidRequestRemoveQueuedPrompt(id: UUID) {}
}
