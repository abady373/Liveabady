// Runs the actual converter on macOS CI. No Photos permission or signing needed.
import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum SmokeFailure: Error { case failed(String) }

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw SmokeFailure.failed(message) }
}

func makeFixture(at url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.gif.identifier as CFString, 2, nil),
          let context = CGContext(data: nil, width: 64, height: 64,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw SmokeFailure.failed("Cannot create GIF fixture")
    }
    for color in [CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                  CGColor(red: 0, green: 1, blue: 0, alpha: 1)] {
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage() else {
            throw SmokeFailure.failed("Cannot render fixture")
        }
        let options: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
    }
    try require(CGImageDestinationFinalize(destination), "Cannot finish GIF fixture")
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
