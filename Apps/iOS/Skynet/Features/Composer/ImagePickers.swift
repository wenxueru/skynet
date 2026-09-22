import SwiftUI
import PhotosUI

/// System photo picker wrapped for attachment intake. The `PhotosPickerItem`
/// loading is async; bytes land through `onAttach` as a ready `ImageAttachment`.
struct PhotoAttachmentPicker: View {
    let canAttachMore: Bool
    let onAttach: (ImageAttachment) -> Void

    @State private var selectedItem: PhotosPickerItem?
    @State private var isLoading = false

    var body: some View {
        PhotosPicker(
            selection: $selectedItem,
            matching: .images,
            photoLibrary: .shared()
        ) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 34, height: 34)
            } else {
                Image(systemName: "photo.on.rectangle")
                    .font(.body)
                    .frame(width: 34, height: 34)
            }
        }
        .disabled(!canAttachMore || isLoading)
        .accessibilityLabel("Attach a photo")
        .accessibilityIdentifier(A11yID.Composer.attachPhotoButton)
        .onChange(of: selectedItem) { _, newItem in
            guard let newItem else { return }
            isLoading = true
            Task {
                defer { isLoading = false }
                guard let data = try? await newItem.loadTransferable(type: Data.self),
                      !data.isEmpty else {
                    selectedItem = nil
                    return
                }
                let name = "photo-\(String(newItem.itemIdentifier ?? UUID().uuidString).prefix(24)).jpg"
                onAttach(ImageAttachment(fileName: name, mimeType: "image/jpeg", data: data))
                selectedItem = nil
            }
        }
    }
}

/// Camera capture via `UIImagePickerController`. Only offered on devices
/// with a camera; the caller checks `isCameraAvailable`.
struct CameraImagePicker: UIViewControllerRepresentable {
    let onCapture: (ImageAttachment) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraImagePicker

        init(parent: CameraImagePicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            defer { parent.dismiss() }
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.85) else { return }
            parent.onCapture(
                ImageAttachment(fileName: "camera-shot.jpg", mimeType: "image/jpeg", data: data)
            )
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
