import SwiftUI

/// An expandable tool-call row: compact header (kind, title, state, duration)
/// that expands to reveal pretty-printed arguments and output.
struct ToolCallRow: View {
    let record: ToolCallRecord

    @State private var isExpanded = false

    @ViewBuilder
    private var stateIcon: some View {
        switch record.state {
        case .running:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Theme.danger)
        case .canceled:
            Image(systemName: "minus.circle")
                .foregroundStyle(Color.secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: Theme.systemImage(for: record.kind))
                        .font(.subheadline)
                        .foregroundStyle(Theme.color(for: record.state))
                        .frame(width: 24)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: Theme.Spacing.xs) {
                            Text(record.kind.displayName)
                            if let duration = record.duration {
                                Text("· \(SkynetFormatters.duration(duration))")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                    }

                    Spacer(minLength: Theme.Spacing.sm)

                    stateIcon
                        .accessibilityLabel(record.state == .running ? "Running" : record.state.rawValue)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .accessibilityHidden(true)
                }
                .padding(Theme.Spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11yID.Session.toolCallToggle(record.id))
            .accessibilityHint("Expands the tool call's arguments and output")

            if isExpanded {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if let arguments = record.arguments, !arguments.isEmpty {
                        sectionLabel("Arguments")
                        codeBlock(arguments)
                    }
                    if let output = record.output, !output.isEmpty {
                        sectionLabel("Output")
                        codeBlock(output)
                        if record.outputTruncated {
                            Text("Output truncated by the relay")
                                .font(Theme.monoCaption)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.bottom, Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityIdentifier(A11yID.Session.toolCallOutput(record.id))
            }
        }
        .background(Theme.toolCallBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.secondary)
    }

    private func codeBlock(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(Theme.monoFootnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Spacing.md)
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }
}

#Preview("Tool calls") {
    VStack(spacing: 12) {
        if case .toolCall(let record) = PreviewData.transcript[2] {
            ToolCallRow(record: record)
        }
        if case .toolCall(let record) = PreviewData.transcript[3] {
            ToolCallRow(record: record)
        }
    }
    .padding()
}
