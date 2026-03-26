import SwiftUI
import PhotosUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Photo Library Picker (PHPicker — camera roll)

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: dismiss)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onCapture: (UIImage) -> Void
        let dismiss: DismissAction

        init(onCapture: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                dismiss()
                return
            }

            provider.loadObject(ofClass: UIImage.self) { image, _ in
                let uiImage = image as? UIImage
                Task { @MainActor [weak self] in
                    if let uiImage {
                        self?.onCapture(uiImage)
                    }
                    self?.dismiss()
                }
            }
        }
    }
}

// MARK: - Camera Picker (UIImagePickerController — camera only)

struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let dismiss: DismissAction

        init(onCapture: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

// MARK: - Document Picker (images + PDFs)

struct DocumentPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.image, .pdf]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onCapture: (UIImage) -> Void
        let dismiss: DismissAction

        init(onCapture: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                dismiss()
                return
            }

            let accessing = url.startAccessingSecurityScopedResource()

            print("DocumentPicker: picked \(url.lastPathComponent), extension: \(url.pathExtension), accessing: \(accessing)")

            let image: UIImage?
            if url.pathExtension.lowercased() == "pdf" {
                image = renderPDFToImage(url: url)
                print("DocumentPicker: PDF render result: \(image != nil)")
            } else {
                image = loadImage(url: url)
                print("DocumentPicker: image load result: \(image != nil)")
            }

            if accessing { url.stopAccessingSecurityScopedResource() }

            let capturedImage = image
            let onCapture = self.onCapture
            let dismiss = self.dismiss
            Task { @MainActor in
                if let capturedImage {
                    onCapture(capturedImage)
                }
                dismiss()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            dismiss()
        }

        private func loadImage(url: URL) -> UIImage? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }

        private func renderPDFToImage(url: URL) -> UIImage? {
            guard let document = PDFDocument(url: url),
                  let page = document.page(at: 0) else { return nil }
            return page.thumbnail(of: CGSize(width: 2048, height: 2048), for: .mediaBox)
        }
    }
}
