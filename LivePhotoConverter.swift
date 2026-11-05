import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

struct LivePhotoResources {
    let directory: URL
    let photoURL: URL
    let videoURL: URL
}

enum ConversionError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// A paired JPEG + MOV, not a promise of Lock Screen wallpaper eligibility.
final class LivePhotoConverter {
    // Native iPhone 14 Plus aspect ratio. These are app choices, not Apple's
    // documented requirements for accepting a Live Photo as a wallpaper.
    static let width = 1284
    static let height = 2778
    static let fps: Int32 = 30
    static let maximumDuration = 3.0

    func convert(sourceURL: URL,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> LivePhotoResources {
        let frames: FrameSource
        if let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let type = CGImageSourceGetType(source), type as String == UTType.gif.identifier {
            frames = try GIFFrames(source: source)
        } else {
            let asset = AVURLAsset(url: sourceURL)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                throw ConversionError.message("لا يحتوي الملف المختار على مسار فيديو قابل للقراءة.")
            }
            let trackRange = try await track.load(.timeRange)
            let assetDuration = try await asset.load(.duration)
            let range = CMTimeRangeGetIntersection(trackRange,
                otherRange: CMTimeRange(start: .zero, duration: assetDuration))
            guard range.start.seconds.isFinite, range.duration.seconds.isFinite,
                  range.duration.seconds >= 0.1 else {
                throw ConversionError.message("اختر فيديو قابلاً للقراءة ومدته عُشر ثانية على الأقل.")
            }
            frames = VideoFrames(asset: asset, range: range)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "arabic-live-photo.encoding", qos: .userInitiated)
            queue.async {
                do {
                    let job = try EncodingJob(frames: frames, queue: queue,
                                              progress: progress, continuation: continuation)
                    job.start()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private protocol FrameSource: AnyObject {
    var duration: Double { get }
    func image(at seconds: Double) throws -> CGImage
}

private final class VideoFrames: FrameSource {
    let duration: Double
    private let generator: AVAssetImageGenerator
    private let start: CMTime

    init(asset: AVAsset, range: CMTimeRange) {
        duration = min(range.duration.seconds, LivePhotoConverter.maximumDuration)
        start = range.start
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2778, height: 2778)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
    }

    func image(at seconds: Double) throws -> CGImage {
        // Synchronous decoding deliberately runs only on the encoding queue.
        try generator.copyCGImage(at: CMTimeAdd(start, CMTime(seconds: seconds, preferredTimescale: 600)),
                                  actualTime: nil)
    }
}

private final class GIFFrames: FrameSource {
    let duration: Double
    private let source: CGImageSource
    private let endTimes: [Double]
    private var cachedIndex = -1
    private var cachedImage: CGImage?

    init(source: CGImageSource) throws {
        self.source = source
        let count = CGImageSourceGetCount(source)
        guard count > 1 else {
            throw ConversionError.message("الملف المختار ليس GIF متحركاً.")
        }
        var times: [Double] = []
        var total = 0.0
        // Only inspect frames needed for the first three seconds.
        for index in 0..<min(count, 5000) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime as String] as? NSNumber)?.doubleValue ?? 0.1
            // Guard against broken zero/non-finite GIF delays.
            total += delay.isFinite && delay > 0 ? max(0.02, delay) : 0.1
            times.append(total)
            if total >= LivePhotoConverter.maximumDuration { break }
        }
        endTimes = times
        duration = min(total, LivePhotoConverter.maximumDuration)
    }

    func image(at seconds: Double) throws -> CGImage {
        let index = endTimes.firstIndex(where: { seconds < $0 }) ?? (endTimes.count - 1)
        if index == cachedIndex, let cachedImage { return cachedImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2778,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw ConversionError.message("تعذّر فك أحد إطارات GIF.")
        }
        cachedImage = image
        cachedIndex = index
        return image
    }
}

/// All mutable encoding state is confined to one serial queue.
private final class EncodingJob {
    private let frames: FrameSource
    private let queue: DispatchQueue
    private let progress: @Sendable (Double) -> Void
    private let continuation: CheckedContinuation<LivePhotoResources, Error>
    private let resources: LivePhotoResources
    private let identifier: String
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let metadataInput: AVAssetWriterInput
    private let pixels: AVAssetWriterInputPixelBufferAdaptor
    private let metadata: AVAssetWriterInputMetadataAdaptor
    private let frameCount: Int
    private var nextFrame = 0
    private var videoDone = false
    private var metadataDone = false
    private var finishing = false
    private var completed = false

    init(frames: FrameSource, queue: DispatchQueue,
         progress: @escaping @Sendable (Double) -> Void,
         continuation: CheckedContinuation<LivePhotoResources, Error>) throws {
        self.frames = frames
        self.queue = queue
        self.progress = progress
        self.continuation = continuation
        let identifier = UUID().uuidString
        self.identifier = identifier
        frameCount = max(2, Int(ceil(frames.duration * Double(LivePhotoConverter.fps))))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivePhoto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resources = LivePhotoResources(directory: directory,
                                       photoURL: directory.appendingPathComponent("photo.jpg"),
                                       videoURL: directory.appendingPathComponent("paired.mov"))
        self.resources = resources
        do {
            let writer = try AVAssetWriter(outputURL: resources.videoURL, fileType: .mov)
            let contentID = AVMutableMetadataItem()
            contentID.identifier = .quickTimeMetadataContentIdentifier
            contentID.dataType = kCMMetadataBaseDataType_UTF8 as String
            contentID.value = identifier as NSString
            writer.metadata = [contentID]

            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: LivePhotoConverter.width,
                AVVideoHeightKey: LivePhotoConverter.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 12_000_000,
                    AVVideoExpectedSourceFrameRateKey: LivePhotoConverter.fps,
                    AVVideoMaxKeyFrameIntervalKey: LivePhotoConverter.fps,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ],
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ]
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            videoInput.expectsMediaDataInRealTime = false
            let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: LivePhotoConverter.width,
                    kCVPixelBufferHeightKey as String: LivePhotoConverter.height,
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
                ])

            var description: CMFormatDescription?
            let specification: [String: Any] = [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                    "mdta/com.apple.quicktime.still-image-time",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                    kCMMetadataBaseDataType_SInt8 as String
            ]
            let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
                metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &description)
            guard status == noErr, let description else {
                throw ConversionError.message("تعذّر إنشاء مسار توقيت الصورة الثابتة.")
            }
            let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil,
                                               sourceFormatHint: description)
            metadataInput.expectsMediaDataInRealTime = false
            let metadata = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
            guard writer.canAdd(videoInput), writer.canAdd(metadataInput) else {
                throw ConversionError.message("الجهاز لا يدعم إعدادات التصدير المختارة.")
            }
            writer.add(videoInput)
            writer.add(metadataInput)
            self.writer = writer
            self.videoInput = videoInput
            self.pixels = pixels
            self.metadataInput = metadataInput
            self.metadata = metadata
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func start() {
        guard writer.startWriting() else {
            fail(writer.error ?? ConversionError.message("تعذّر بدء كتابة الفيديو."))
            return
        }
        writer.startSession(atSourceTime: .zero)
        metadataInput.requestMediaDataWhenReady(on: queue) { [self] in
            guard !completed, !metadataDone, metadataInput.isReadyForMoreMediaData else { return }
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = "com.apple.quicktime.still-image-time" as NSString
            item.dataType = kCMMetadataBaseDataType_SInt8 as String
            item.value = NSNumber(value: Int8(0))
            let group = AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(
                start: .zero, duration: CMTime(value: 1, timescale: LivePhotoConverter.fps)))
            guard metadata.append(group) else {
                fail(writer.error ?? ConversionError.message("تعذّرت كتابة توقيت الصورة."))
                return
            }
            metadataDone = true
            metadataInput.markAsFinished()
            metadataInput.stopRequestingMediaData()
            finishIfReady()
        }
        videoInput.requestMediaDataWhenReady(on: queue) { [self] in
            guard !completed, !videoDone else { return }
            do {
                while videoInput.isReadyForMoreMediaData && nextFrame < frameCount {
                    try autoreleasepool {
                        let time = CMTime(value: Int64(nextFrame), timescale: LivePhotoConverter.fps)
                        let image = try frames.image(at: time.seconds)
                        let (buffer, renderedImage) = try render(image)
                        if nextFrame == 0 { try writePhoto(renderedImage) }
                        guard pixels.append(buffer, withPresentationTime: time) else {
                            throw writer.error ?? ConversionError.message("تعذّرت كتابة إطار الفيديو.")
                        }
                    }
                    nextFrame += 1
                    progress(Double(nextFrame) / Double(frameCount))
                }
                if nextFrame == frameCount {
                    videoDone = true
                    videoInput.markAsFinished()
                    videoInput.stopRequestingMediaData()
                    finishIfReady()
                }
            } catch { fail(error) }
        }
    }

    private func render(_ image: CGImage) throws -> (CVPixelBuffer, CGImage) {
        guard let pool = pixels.pixelBufferPool else {
            throw ConversionError.message("تعذّر تخصيص ذاكرة الفيديو.")
        }
        var optional: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &optional) == kCVReturnSuccess,
              let buffer = optional else {
            throw ConversionError.message("الذاكرة المتاحة غير كافية لمعالجة الفيديو.")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = LivePhotoConverter.width
        let height = LivePhotoConverter.height
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw ConversionError.message("تعذّر تجهيز إطار الصورة.")
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(width) - size.width) / 2,
                                      y: (CGFloat(height) - size.height) / 2,
                                      width: size.width, height: size.height))
        guard let rendered = context.makeImage() else {
            throw ConversionError.message("تعذّر استخراج الصورة الثابتة.")
        }
        return (buffer, rendered)
    }

    private func writePhoto(_ image: CGImage) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            resources.photoURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ConversionError.message("تعذّر إنشاء ملف الصورة.")
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyMakerAppleDictionary: ["17": identifier]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.message("تعذّر حفظ بيانات الصورة.")
        }
    }

    private func finishIfReady() {
        guard videoDone, metadataDone, !finishing, !completed else { return }
        finishing = true
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: LivePhotoConverter.fps))
        writer.finishWriting { [self] in
            queue.async { [self] in
                guard !completed else { return }
                if writer.status == .completed {
                    completed = true
                    continuation.resume(returning: resources)
                } else {
                    fail(writer.error ?? ConversionError.message("لم يكتمل تصدير Live Photo."))
                }
            }
        }
    }

    private func fail(_ error: Error) {
        guard !completed else { return }
        completed = true
        videoInput.stopRequestingMediaData()
        metadataInput.stopRequestingMediaData()
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: resources.directory)
        continuation.resume(throwing: error)
    }
}
