import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct MediaPicker: UIViewControllerRepresentable {
    let onPick: (Result<URL, Error>) -> Void
    let onImportStarted: () -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onImportStarted: onImportStarted, onDismiss: { dismiss() })
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 1
        configuration.filter = .any(of: [.videos, .images, .livePhotos])
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPick: (Result<URL, Error>) -> Void
        private let onImportStarted: () -> Void
        private let onDismiss: () -> Void
        private var hasSelection = false

        init(onPick: @escaping (Result<URL, Error>) -> Void,
             onImportStarted: @escaping () -> Void, onDismiss: @escaping () -> Void) {
            self.onPick = onPick
            self.onImportStarted = onImportStarted
            self.onDismiss = onDismiss
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !hasSelection else { return }
            guard let provider = results.first?.itemProvider else {
                onDismiss()
                return
            }
            hasSelection = true
            onImportStarted()
            onDismiss()

            // Prefer the movie component of an existing Live Photo.
            if provider.canLoadObject(ofClass: PHLivePhoto.self) {
                provider.loadObject(ofClass: PHLivePhoto.self) { object, error in
                    guard let livePhoto = object as? PHLivePhoto else {
                        self.deliver(.failure(error ?? ImportError.unreadable))
                        return
                    }
                    self.copyLivePhotoVideo(livePhoto)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                copyFile(from: provider, type: UTType.movie.identifier, fallbackExtension: "mov")
            } else if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier) {
                copyFile(from: provider, type: UTType.gif.identifier, fallbackExtension: "gif")
            } else {
                deliver(.failure(ImportError.unsupported))
            }
        }

        private func copyFile(from provider: NSItemProvider, type: String, fallbackExtension: String) {
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else {
                    self.deliver(.failure(error ?? ImportError.unreadable))
                    return
                }
                var directory: URL?
                do {
                    let destinationDirectory = try Self.makeDirectory()
                    directory = destinationDirectory
                    let pathExtension = url.pathExtension.isEmpty ? fallbackExtension : url.pathExtension
                    let destination = destinationDirectory.appendingPathComponent("input.\(pathExtension)")
                    // The provider URL is valid only for this callback. Copy before returning.
                    try FileManager.default.copyItem(at: url, to: destination)
                    self.deliver(.success(destination))
                } catch {
                    if let directory { try? FileManager.default.removeItem(at: directory) }
                    self.deliver(.failure(error))
                }
            }
        }

        private func copyLivePhotoVideo(_ photo: PHLivePhoto) {
            let resources = PHAssetResource.assetResources(for: photo)
            guard let video = resources.first(where: { $0.type == .pairedVideo })
                    ?? resources.first(where: { $0.type == .fullSizePairedVideo }) else {
                deliver(.failure(ImportError.unreadable))
                return
            }
            do {
                let directory = try Self.makeDirectory()
                let url = directory.appendingPathComponent("input.mov")
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                PHAssetResourceManager.default().writeData(for: video, toFile: url, options: options) { error in
                    if let error {
                        try? FileManager.default.removeItem(at: directory)
                        self.deliver(.failure(error))
                    } else {
                        self.deliver(.success(url))
                    }
                }
            } catch { deliver(.failure(error)) }
        }

        private static func makeDirectory() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("LivePhotoImport-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        private func deliver(_ result: Result<URL, Error>) {
            DispatchQueue.main.async { self.onPick(result) }
        }
    }
}

enum ImportError: LocalizedError {
    case unsupported, unreadable

    var errorDescription: String? {
        switch self {
        case .unsupported: return "اختر فيديو أو ملف GIF متحركاً أو صورة حية. الصور الثابتة غير مدعومة."
        case .unreadable: return "تعذّر استيراد الوسائط. تأكد من تنزيلها من آي كلاود، ثم حاول مجدداً."
        }
    }
}
