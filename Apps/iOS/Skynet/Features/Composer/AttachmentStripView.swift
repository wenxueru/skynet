import SkynetMobile
import SwiftUI

/// Horizontal strip of pending attachments above the composer field, each
/// with a remove button.
struct AttachmentStripView: View {
    let attachments: [ImageAttachment]
    let onRemove: (UUID) -> Void

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(attachments) { attachment in
                        attachmentTile(attachment)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
            }
            .accessibilityIdentifier(A11yID.Composer.attachmentStrip)
        }
    }

    private func attachmentTile(_ attachment: ImageAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            AttachmentImageView(attachment: attachment, size: 56)

            Button {
                onRemove(attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.white, Color.black.opacity(0.65))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment \(attachment.fileName)")
            .accessibilityIdentifier(A11yID.Composer.attachmentRemove(attachment.id))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachment \(attachment.fileName), \(SkynetFormatters.byteCount(attachment.byteCount))")
        .accessibilityIdentifier(A11yID.Composer.attachment(attachment.id))
    }
}

#Preview("Attachment strip") {
    VStack {
        AttachmentStripView(
            attachments: [
                PreviewData.attachment(name: "log.png"),
                PreviewData.attachment(name: "screenshot.png"),
            ],
            onRemove: { _ in }
        )
        Spacer()
    }
}
