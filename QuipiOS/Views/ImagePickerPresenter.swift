import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Wraps `PHPickerViewController` — single-select, images only.
struct LibraryImagePicker: UIViewControllerRepresentable {

    let onPicked: (UIImage, _ mimeType: String, _ filename: String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: LibraryImagePicker

        init(parent: LibraryImagePicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let result = results.first else {
                parent.onCancel()
                return
            }
            let provider = result.itemProvider
            let suggestedName = provider.suggestedName ?? "image"

            // Prefer PNG when advertised (screenshots typically do).
            if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
                    guard let data, let image = UIImage(data: data) else { return }
                    DispatchQueue.main.async {
                        self.parent.onPicked(image, "image/png", suggestedName + ".png")
                    }
                }
                return
            }

            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    guard let image = object as? UIImage else { return }
                    DispatchQueue.main.async {
                        self.parent.onPicked(image, "image/jpeg", suggestedName + ".jpg")
                    }
                }
            } else {
                DispatchQueue.main.async { self.parent.onCancel() }
            }
        }
    }
}

/// Wraps `UIImagePickerController` in camera mode.
struct CameraImagePicker: UIViewControllerRepresentable {

    let onPicked: (UIImage, _ mimeType: String, _ filename: String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = .camera
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraImagePicker

        init(parent: CameraImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = (info[.originalImage] as? UIImage) ?? (info[.editedImage] as? UIImage)
            picker.dismiss(animated: true)
            if let image {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd-HHmmss"
                let name = "photo-\(formatter.string(from: Date())).jpg"
                parent.onPicked(image, "image/jpeg", name)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            parent.onCancel()
        }
    }
}
