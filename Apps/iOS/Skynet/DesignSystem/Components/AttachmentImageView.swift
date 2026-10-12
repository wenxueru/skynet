import SkynetMobile
import SwiftUI

/// Shared pixels and fallback; callers own labels, actions and row layout.
struct AttachmentImageView: View {
    let attachment: ImageAttachment
    let size: CGFloat
    var placeholderOpacity = 0.15

    var body: some View {
        Group {
            if let image = UIImage(data: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(placeholderOpacity))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(Color.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }
}
