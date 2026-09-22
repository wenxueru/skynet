import SkynetCore
import SwiftUI

struct ProviderSettingsView: View {
    @Bindable var model: AppModel
    @State private var name = ""
    @State private var executable = ""
    @State private var arguments = ""

    var body: some View {
        Form {
            Section("Built in") {
                LabeledContent("Codex", value: "codex")
                LabeledContent("Claude Code", value: "claude")
            }
            Section("Claude Code-compatible wrapper") {
                TextField("Display name", text: $name)
                TextField("Executable path", text: $executable)
                TextField("Default arguments", text: $arguments)
                Button("Save provider") {
                    model.saveCustomProvider(name: name, executable: executable, arguments: arguments)
                    name = ""
                    executable = ""
                    arguments = ""
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || executable.isEmpty)
            }
            Section("Available providers") {
                ForEach(model.providers, id: \.id) { provider in
                    LabeledContent(provider.displayName, value: provider.kind.displayName)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
