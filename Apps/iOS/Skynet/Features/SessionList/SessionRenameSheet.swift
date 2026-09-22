import SwiftUI

/// Small sheet for renaming a session. Keeps its own draft so canceling is
/// always free of side effects.
struct SessionRenameSheet: View {
    @State private var draftTitle: String
    @Environment(\.dismiss) private var dismiss

    private let session: AgentSession
    private let onSave: (String) -> Void

    init(session: AgentSession, onSave: @escaping (String) -> Void) {
        self.session = session
        self.onSave = onSave
        _draftTitle = State(initialValue: session.title)
    }

    private var trimmedDraft: String {
        draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Session name", text: $draftTitle)
                        .textInputAutocapitalization(.sentences)
                        .onSubmit(save)
                        .accessibilityIdentifier(A11yID.SessionList.renameAction(session.id))
                } footer: {
                    Text("A short name helps you find this session later.")
                }
            }
            .navigationTitle("Rename Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmedDraft.isEmpty || trimmedDraft == session.title)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard !trimmedDraft.isEmpty else { return }
        onSave(trimmedDraft)
        dismiss()
    }
}

#Preview("Rename sheet") {
    SessionRenameSheet(session: PreviewData.runningSession) { _ in }
}
