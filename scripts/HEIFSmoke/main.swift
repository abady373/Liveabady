// Runs the actual converter on macOS CI. No Photos permission or signing needed.
import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Photos

enum SmokeFailure: Error { case failed(String) }

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw SmokeFailure.failed(message) }
}

func makeFixture(at url: URL, delays: [Double] = [0.1, 0.1]) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.gif.identifier as CFString, delays.count, nil),
          let context = CGContext(data: nil, width: 64, height: 64,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw SmokeFailure.failed("Cannot create GIF fixture")
    }
    let colors = [CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                  CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                  CGColor(red: 0, green: 0, blue: 1, alpha: 1),
                  CGColor(red: 1, green: 1, blue: 0, alpha: 1)]
    for (index, delay) in delays.enumerated() {
        let color = colors[index % colors.count]
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage() else {
            throw SmokeFailure.failed("Cannot render fixture")
        }
        let options: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
    }
    try require(CGImageDestinationFinalize(destination), "Cannot finish GIF fixture")
}

func thumbnailBytes(_ image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
    try bytes.withUnsafeMutableBytes { pointer in
        guard let context = CGContext(data: pointer.baseAddress, width: 32, height: 32,
            bitsPerComponent: 8, bytesPerRow: 32 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SmokeFailure.failed("Cannot compare loop frames")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
    }
    return bytes
}

func verifyMOV(_ resources: LivePhotoResources, expectedFrameCount: Int) async throws {
    let asset = AVURLAsset(url: resources.videoURL)
    let duration = try await asset.load(.duration)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else { throw SmokeFailure.failed("Missing video") }
    let rate = try await track.load(.nominalFrameRate)
    let descriptions = try await track.load(.formatDescriptions)
    let range = try await track.load(.timeRange)
    try require(descriptions.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC }, "Not HEVC")
    try require(abs(rate - 30) < 0.01, "Not 30 FPS")
    try require(CMTimeCompare(range.start, .zero) == 0, "Video does not start at zero")
    let expectedDuration = CMTime(value: Int64(expectedFrameCount), timescale: 30)
    try require(CMTimeCompare(duration, expectedDuration) == 0, "Wrong exact duration")
    try require(duration.seconds >= 1 && duration.seconds <= 3, "Duration outside 1...3 seconds")

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    try require(reader.startReading(), "Cannot inspect compressed HEVC samples")
    var count = 0
    var lastSync = -1
    while let sample = output.copyNextSampleBuffer() {
        let expectedTime = CMTime(value: Int64(count), timescale: 30)
        try require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), expectedTime) == 0,
                    "Nonuniform sample timing")
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
        if !notSync {
            if lastSync >= 0 { try require(count - lastSync <= 30, "Keyframe interval exceeds 30 frames") }
            lastSync = count
        }
        try require(lastSync >= 0, "First frame is not a sync frame")
        count += 1
    }
    try require(reader.status == .completed && count == expectedFrameCount, "Wrong sample count")
    try require(count - lastSync <= 30, "Final GOP exceeds 30 frames")

    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let first = try thumbnailBytes(generator.copyCGImage(at: .zero, actualTime: nil))
    let lastTime = CMTime(value: Int64(count - 1), timescale: 30)
    let last = try thumbnailBytes(generator.copyCGImage(at: lastTime, actualTime: nil))
    var totalDifference = 0.0
    for index in first.indices where index % 4 != 3 {
        totalDifference += abs(Double(first[index]) - Double(last[index]))
    }
    let difference = totalDifference / 3072.0
    try require(difference < 8, "Loop endpoint differs excessively from the first frame")
    print("PASS: HEVC, 30 FPS, \(count) samples, exact duration \(duration.seconds)s, max GOP30 and blended loop endpoint")
}

func verifyConversion() async throws {
    let fixtureDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HEIFSmoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
    let fixture = fixtureDirectory.appendingPathComponent("fixture.gif")
    try makeFixture(at: fixture)
    let result = try await LivePhotoConverter().convert(sourceURL: fixture) { _ in }
    defer { try? FileManager.default.removeItem(at: result.directory) }

    try require(result.photoURL.pathExtension == "heic", "Wrong still extension")
    guard let imageSource = CGImageSourceCreateWithURL(result.photoURL as CFURL, nil),
          let type = CGImageSourceGetType(imageSource),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
          let makerApple = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
          let identifier = makerApple["17"] as? String else {
        throw SmokeFailure.failed("Missing decodable still or pairing identifier")
    }
    try require(type as String == UTType.heic.identifier, "Still is not real HEIC")
    try require(image.width == 1284 && image.height == 2778, "Wrong still dimensions")

    let asset = AVURLAsset(url: result.videoURL)
    let metadata = try await asset.load(.metadata)
    guard let contentID = metadata.first(where: { $0.identifier == .quickTimeMetadataContentIdentifier }) else {
        throw SmokeFailure.failed("Missing MOV identifier")
    }
    let movieIdentifier = try await contentID.load(.stringValue)
    try require(movieIdentifier == identifier, "HEIC and MOV identifiers differ")
    let tracks = try await asset.loadTracks(withMediaType: .metadata)
    guard let track = tracks.first else {
        throw SmokeFailure.failed("Missing timed metadata track")
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    try require(reader.canAdd(output), "Cannot inspect timed metadata")
    reader.add(output)
    let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
    try require(reader.startReading(), "Cannot read timed metadata")
    var foundStillTime = false
    while let group = adaptor.nextTimedMetadataGroup() {
        if group.items.contains(where: {
            ($0.key as? String) == "com.apple.quicktime.still-image-time"
        }) {
            try require(CMTimeCompare(group.timeRange.start, .zero) == 0, "Still time is not the first frame")
            foundStillTime = true
        }
    }
    try require(reader.status == .completed, "Metadata reading did not complete")
    try require(foundStillTime, "Missing still-image-time marker")
    print("PASS: production converter created decodable public.heic at 1284x2778")
    print("PASS: HEIC/MOV identifiers match and still-image-time starts at zero")

    // Run the same validation and PhotoKit loader used by the iPhone app.
    _ = try await PhotoLibraryService.preview(result)
    print("PASS: PhotoKit loaded the final Live Photo with photo and paired-video resources")
    let mismatched = LivePhotoResources(directory: result.directory,
        photoURL: result.photoURL, videoURL: result.videoURL,
        assetIdentifier: UUID().uuidString, photoTime: result.photoTime)
    var rejectedMismatch = false
    do { try await LivePhotoPairValidator.validate(mismatched) }
    catch { rejectedMismatch = true }
    try require(rejectedMismatch, "Validator accepted a mismatched AssetIdentifier")
    print("PASS: mismatched AssetIdentifier was rejected")
    try await verifyMOV(result, expectedFrameCount: 30)

    for (name, delays, expectedCount) in [
        ("fractional", Array(repeating: 0.11, count: 13), 43),
        ("long", Array(repeating: 0.9, count: 4), 90)
    ] {
        let source = fixtureDirectory.appendingPathComponent("\(name).gif")
        try makeFixture(at: source, delays: delays)
        let converted = try await LivePhotoConverter().convert(sourceURL: source) { _ in }
        defer { try? FileManager.default.removeItem(at: converted.directory) }
        try await LivePhotoPairValidator.validate(converted)
        try await verifyMOV(converted, expectedFrameCount: expectedCount)
    }
    // Also exercise AVFoundation video import, rather than GIF only.
    let fromVideo = try await LivePhotoConverter().convert(sourceURL: result.videoURL) { _ in }
    defer { try? FileManager.default.removeItem(at: fromVideo.directory) }
    try await verifyMOV(fromVideo, expectedFrameCount: 30)
}

DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
    fputs("PhotoKit conversion check timed out\n", stderr)
    exit(1)
}
Task {
    do {
        try await verifyConversion()
        exit(0)
    } catch {
        fputs("HEIF conversion smoke check failed: \(error)\n", stderr)
        exit(1)
    }
}
dispatchMain()
