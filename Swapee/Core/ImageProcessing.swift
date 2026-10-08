import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo that's ready to upload.
nonisolated struct ProcessedPhoto: Sendable, Equatable {
    /// JPEG with a long edge of at most 1600 px and no EXIF or GPS data.
    let jpeg: Data
    /// EXIF `DateTimeOriginal` as `yyyy-MM-ddTHH:mm:ss` (the photographer's local time, no offset); nil if unavailable.
    let takenAt: String?
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Downscales, reads the capture time, and strips metadata. Runs synchronously on the caller's thread, so call it off the main actor.
nonisolated enum ImageProcessing {
    static let maxPixelSize = 1600
    static let jpegQuality = 0.8

    enum Failure: Error {
        case unreadable
        case encodingFailed
        case metadataNotRemoved
    }

    static func process(_ data: Data) throws -> ProcessedPhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw Failure.unreadable
        }

        // Read the capture time first; re-encoding drops it.
        let takenAt = takenAt(from: source)

        // Thumbnail from the original: applies orientation, never upscales, carries no metadata.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadable
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.encodingFailed
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure.encodingFailed
        }

        let jpeg = output as Data
        // Don't assume the metadata is gone; check the output.
        guard !containsPersonalMetadata(jpeg) else {
            throw Failure.metadataNotRemoved
        }
        return ProcessedPhoto(jpeg: jpeg, takenAt: takenAt, pixelWidth: image.width, pixelHeight: image.height)
    }

    /// A profile photo: the centered square, 512 × 512, no metadata.
    static func avatar(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1536,
              ] as CFDictionary) else {
            throw Failure.unreadable
        }
        let side = min(image.width, image.height)
        let crop = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        guard let square = image.cropping(to: crop) else { throw Failure.unreadable }

        let size = min(512, side)
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw Failure.encodingFailed }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let scaled = context.makeImage() else { throw Failure.encodingFailed }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.encodingFailed
        }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        let jpeg = output as Data
        guard !containsPersonalMetadata(jpeg) else { throw Failure.metadataNotRemoved }
        return jpeg
    }

    /// EXIF `yyyy:MM:dd HH:mm:ss` → `yyyy-MM-ddTHH:mm:ss`. Malformed or implausible values count as unavailable; never guess.
    static func takenAt(from source: CGImageSource) -> String? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
              let m = raw.trimmingCharacters(in: .whitespaces)
                  .wholeMatch(of: /(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})/),
              let year = Int(m.1), let month = Int(m.2), let day = Int(m.3),
              let hour = Int(m.4), let minute = Int(m.5), let second = Int(m.6),
              (1990...2100).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second)
        else {
            return nil
        }
        return "\(m.1)-\(m.2)-\(m.3)T\(m.4):\(m.5):\(m.6)"
    }

    /// True if GPS, capture time, or camera details remain.
    static func containsPersonalMetadata(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return true
        }
        if properties[kCGImagePropertyGPSDictionary] != nil { return true }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           exif[kCGImagePropertyExifDateTimeOriginal] != nil || exif[kCGImagePropertyExifLensModel] != nil {
            return true
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           tiff[kCGImagePropertyTIFFMake] != nil || tiff[kCGImagePropertyTIFFModel] != nil {
            return true
        }
        return false
    }
}
