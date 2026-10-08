import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Swapee

struct ImageProcessingTests {
    @Test func stripsLocationAndCameraMetadataFromJPEG() throws {
        let original = try SamplePhoto.make(width: 4032, height: 3024, type: .jpeg)
        #expect(ImageProcessing.containsPersonalMetadata(original), "the sample must start with GPS and EXIF")

        let processed = try ImageProcessing.process(original)

        let properties = try SamplePhoto.properties(of: processed.jpeg)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(!ImageProcessing.containsPersonalMetadata(processed.jpeg))
    }

    @Test(.enabled(if: SamplePhoto.canEncodeHEIC))
    func stripsLocationAndCameraMetadataFromHEIC() throws {
        let original = try SamplePhoto.make(width: 4032, height: 3024, type: .heic)
        #expect(ImageProcessing.containsPersonalMetadata(original))

        let processed = try ImageProcessing.process(original)

        #expect(!ImageProcessing.containsPersonalMetadata(processed.jpeg))
        #expect(processed.takenAt == "2026-10-06T21:14:00")
    }

    @Test func readsCaptureTimeBeforeStrippingIt() throws {
        let processed = try ImageProcessing.process(try SamplePhoto.make(width: 1000, height: 800, type: .jpeg))
        #expect(processed.takenAt == "2026-10-06T21:14:00")
    }

    @Test func outputIsJPEG() throws {
        let processed = try ImageProcessing.process(try SamplePhoto.make(width: 1000, height: 800, type: .png))
        let source = try #require(CGImageSourceCreateWithData(processed.jpeg as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
    }

    @Test func downscalesLongEdgeTo1600() throws {
        let processed = try ImageProcessing.process(try SamplePhoto.make(width: 4032, height: 3024, type: .jpeg))
        #expect(processed.pixelWidth == 1600)
        #expect(processed.pixelHeight == 1200)
    }

    @Test func appliesOrientation() throws {
        // Portrait shots are stored landscape with orientation 6 (rotate 90° clockwise).
        let processed = try ImageProcessing.process(
            try SamplePhoto.make(width: 4032, height: 3024, type: .jpeg, orientation: .right)
        )
        #expect(processed.pixelWidth == 1200)
        #expect(processed.pixelHeight == 1600)
    }

    @Test func neverUpscales() throws {
        let processed = try ImageProcessing.process(try SamplePhoto.make(width: 800, height: 600, type: .jpeg))
        #expect(processed.pixelWidth == 800)
        #expect(processed.pixelHeight == 600)
    }

    @Test func screenshotsHaveNoCaptureTime() throws {
        let screenshot = try SamplePhoto.make(width: 1206, height: 2622, type: .png, metadata: false)
        #expect(try ImageProcessing.process(screenshot).takenAt == nil)
    }

    @Test(arguments: ["0000:00:00 00:00:00", "2026:13:01 10:00:00", "2026-10-06 21:14:00", "yesterday"])
    func implausibleCaptureTimesAreIgnored(raw: String) throws {
        let photo = try SamplePhoto.make(width: 400, height: 300, type: .jpeg, dateTimeOriginal: raw)
        #expect(try ImageProcessing.process(photo).takenAt == nil)
    }

    @Test func avatarsAreSquareAndClean() throws {
        let avatar = try ImageProcessing.avatar(try SamplePhoto.make(width: 4032, height: 3024, type: .jpeg, orientation: .right))
        let properties = try SamplePhoto.properties(of: avatar)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 512)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 512)
        #expect(!ImageProcessing.containsPersonalMetadata(avatar))
    }

    @Test func rejectsDataThatIsNotAnImage() {
        #expect(throws: ImageProcessing.Failure.self) {
            try ImageProcessing.process(Data("not an image".utf8))
        }
    }
}

/// Builds test images with the metadata a camera would write.
nonisolated enum SamplePhoto {
    static var canEncodeHEIC: Bool {
        (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier)
    }

    static func make(
        width: Int,
        height: Int,
        type: UTType,
        orientation: CGImagePropertyOrientation = .up,
        metadata: Bool = true,
        dateTimeOriginal: String = "2026:10:06 21:14:00"
    ) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        let image = try #require(context.makeImage())

        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation.rawValue]
        if metadata {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 25.0330, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 121.5654, kCGImagePropertyGPSLongitudeRef: "E",
            ]
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: dateTimeOriginal,
                kCGImagePropertyExifLensModel: "iPhone 18 Pro back camera",
            ]
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFMake: "Apple",
                kCGImagePropertyTIFFModel: "iPhone 18 Pro",
            ]
        }

        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func properties(of data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }
}
