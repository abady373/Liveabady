import Foundation
import Photos
import PhotosUI
import CoreGraphics
import UniformTypeIdentifiers

enum PhotoLibraryService {
    /// Photos validation here does not test Lock Screen eligibility.
    static func preview(_ resources: LivePhotoResources) async throws -> PHLivePhoto {
        try await LivePhotoPairValidator.validate(resources)
        return try await withCheckedThrowingContinuation { continuation in
            PHLivePhoto.request(withResourceFileURLs: [resources.photoURL, resources.videoURL],
                                placeholderImage: nil,
                                targetSize: CGSize(width: 428, height: 926),
                                contentMode: .aspectFit) { photo, info in
                // PhotoKit can first deliver a degraded result. Resume only on
                // its final callback, including cancellation/failure.
                if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true { return }
                if (info[PHLivePhotoInfoCancelledKey] as? Bool) == true ||
                    info[PHLivePhotoInfoErrorKey] != nil {
                    continuation.resume(throwing: ConversionError.message(
                        "تعذّر تحميل حركة الصورة الحية كاملة. جرّب إنشاء النتيجة مجدداً."))
                } else if let photo {
                    let components = PHAssetResource.assetResources(for: photo)
                    let hasPhoto = components.contains { $0.type == .photo || $0.type == .fullSizePhoto }
                    let hasVideo = components.contains { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }
                    guard hasPhoto, hasVideo else {
                        continuation.resume(throwing: ConversionError.message(
                            "لم يتعرف النظام على الصورة والفيديو كصورة حية متكاملة."))
                        return
                    }
                    continuation.resume(returning: photo)
                } else {
                    continuation.resume(throwing: ConversionError.message(
                        "تعذّر التحقق من زوج الصورة والفيديو كصورة حية. جرّب مقطعاً آخر."))
                }
            }
        }
    }

    static func save(_ resources: LivePhotoResources) async throws {
        try await LivePhotoPairValidator.validate(resources)
        // PHPicker handles selection without full-library access. Saving only
        // needs add-only access and NSPhotoLibraryAddUsageDescription.
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            throw ConversionError.message(
                "اسمح بإضافة الصور من إعدادات الخصوصية أو إعدادات التطبيق، ثم أعد الحفظ.")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let photoOptions = PHAssetResourceCreationOptions()
                photoOptions.uniformTypeIdentifier = UTType.heic.identifier
                photoOptions.originalFilename = "photo.heic"
                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.uniformTypeIdentifier = "com.apple.quicktime-movie"
                videoOptions.originalFilename = "paired.mov"
                // ONE asset, TWO resources. Do not create separate requests.
                // Keep the local files for preview or retry; do not move them.
                request.addResource(with: .photo, fileURL: resources.photoURL, options: photoOptions)
                request.addResource(with: .pairedVideo, fileURL: resources.videoURL, options: videoOptions)
            }
        } catch {
            throw ConversionError.message(
                "تعذّر حفظ الصورة الحية. تحقّق من مساحة التخزين وصلاحية إضافة الصور، ثم حاول مجدداً.")
        }
    }
}
