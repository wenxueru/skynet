import SwiftUI

/// Renders one transcript item by kind. Row layout mirrors chat apps:
/// user messages hug the trailing edge, everything else fills the width.
struct TranscriptRow: View {
    let item: TranscriptItem
    var highlightQuery: String?
    var onPermissionDecision: ((PermissionRequestRecord, PermissionDecision) -> Void)?

    var body: some View {
        switch item {
        case .userMessage(let message):
            userRow(message)
        case .assistantMessage(let message):
            assistantRow(message)
        case .toolCall(let record):
            ToolCallRow(record: record)
        case .permissionRequest(let record):
            PermissionRequestCard(record: record) { decision in
                onPermissionDecision?(record, decision)
            }
        case .systemNotice(let notice):
            noticeRow(notice)
        }
    }

    // MARK: - User

    private func userRow(_ message: UserMessage) -> some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                if !message.attachments.isEmpty {
                    attachmentStrip(message.attachments)
                }
                LongMessageText(itemID: message.id, text: message.text)
                    .fixedSize(horizontal: false, vertical: true)
                deliveryFooter(message.deliveryState)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .frame(maxWidth: 420, alignment: .trailing)
        }
        .accessibilityIdentifier(A11yID.Session.row(message.id))
    }

    private func attachmentStrip(_ attachments: [ImageAttachment]) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(attachments) { attachment in
                if let image = UIImage(data: attachment.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                        .accessibilityLabel("Attached image \(attachment.fileName)")
                } else {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 72, height: 72)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(Color.secondary)
                        }
                        .accessibilityLabel("Attached image \(attachment.fileName)")
                }
            }
        }
    }

    @ViewBuilder
    private func deliveryFooter(_ state: MessageDeliveryState) -> some View {
        switch state {
        case .delivered:
            EmptyView()
        case .sending:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Sending…")
            }
            .font(.caption2)
            .foregroundStyle(Color.secondary)
        case .queued:
            BadgeView("Queued", tint: Theme.warning)
        case .failed(let reason):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(reason)
            }
            .font(.caption2)
            .foregroundStyle(Theme.danger)
        }
    }

    // MARK: - Assistant

    private func assistantRow(_ message: AssistantMessage) -> some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                LongMessageText(itemID: message.id, text: message.text, query: highlightQuery)
                    .fixedSize(horizontal: false, vertical: true)
                if message.isStreaming {
                    StreamingIndicator()
                } else if let modelID = message.modelID {
                    Text(modelID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.assistantBubble, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .frame(maxWidth: 440, alignment: .leading)
            Spacer(minLength: 48)
        }
        .accessibilityIdentifier(A11yID.Session.row(message.id))
    }

    // MARK: - Notices

    private func noticeRow(_ notice: SystemNotice) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: notice.severity == .info ? "info.circle" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(notice.severity == .error ? Theme.danger : Color.secondary)
                .accessibilityHidden(true)
            Text(notice.text)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityIdentifier(A11yID.Session.row(notice.id))
        .accessibilityElement(children: .combine)
    }
}

#Preview("Transcript rows") {
    ScrollView {
        LazyVStack(spacing: Theme.Spacing.md) {
            ForEach(PreviewData.transcript) { item in
                TranscriptRow(item: item, highlightQuery: nil, onPermissionDecision: nil)
            }
        }
        .padding()
    }
}
