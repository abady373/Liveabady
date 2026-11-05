import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Validates our actual HEIC/MOV resources before PhotoKit preview or saving.
/// This checks the resource pair, not Lock Screen wallpaper eligibility.
enum LivePhotoPairValidator {
    static func validate(_ resources: LivePhotoResources) async throws {
        guard UUID(uuidString: resources.assetIdentifier) != nil,
              let source = CGImageSourceCreateWithURL(resources.photoURL as CFURL, nil),
              let type = CGImageSourceGetType(source), type as String == UTType.heic.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let makerApple = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
              makerApple["17"] as? String == resources.assetIdentifier else {
            throw ConversionError.message("صورة HEIF غير صالحة أو لا تحمل معرّف ربط الصورة الحية الصحيح.")
        }

        let asset = AVURLAsset(url: resources.videoURL)
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0,
              resources.photoTime.seconds.isFinite,
              CMTimeCompare(resources.photoTime, .zero) >= 0,
              CMTimeCompare(resources.photoTime, duration) < 0 else {
            throw ConversionError.message("توقيت الإطار الرئيسي يقع خارج فيديو الحركة.")
        }
        let metadata = try await asset.load(.metadata)
        guard let contentID = metadata.first(where: { $0.identifier == .quickTimeMetadataContentIdentifier }),
              try await contentID.load(.stringValue) == resources.assetIdentifier else {
            throw ConversionError.message("معرّف فيديو MOV لا يطابق معرّف صورة HEIF.")
        }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)
        guard !videoTracks.isEmpty, let metadataTrack = metadataTracks.first else {
            throw ConversionError.message("فيديو الحركة لا يحتوي المسارات اللازمة للصورة الحية.")
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: metadataTrack, outputSettings: nil)
        guard reader.canAdd(output) else {
            throw ConversionError.message("تعذّر التحقق من مسار توقيت الإطار الرئيسي.")
        }
        reader.add(output)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
        guard reader.startReading() else {
            throw ConversionError.message("تعذّرت قراءة بيانات ربط الصورة بفيديو الحركة.")
        }
        var foundPhotoTime = false
        while let group = adaptor.nextTimedMetadataGroup() {
            for item in group.items where item.keySpace == .quickTimeMetadata &&
                (item.key as? String) == "com.apple.quicktime.still-image-time" {
                guard item.dataType == kCMMetadataBaseDataType_SInt8 as String,
                      (item.numberValue?.int8Value) == 0,
                      CMTimeCompare(group.timeRange.start, resources.photoTime) == 0 else {
                    reader.cancelReading()
                    throw ConversionError.message("بيانات توقيت الإطار الرئيسي غير متوافقة مع الصورة.")
                }
                foundPhotoTime = true
            }
        }
        guard reader.status == .completed, foundPhotoTime else {
            throw ConversionError.message("علامة still-image-time مفقودة أو غير قابلة للقراءة.")
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try generator.copyCGImage(at: resources.photoTime, actualTime: nil)
        guard frame.width == image.width, frame.height == image.height else {
            throw ConversionError.message("أبعاد الإطار الرئيسي واتجاهه لا يطابقان صورة HEIF.")
        }
    }
}
