import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system camera. Hands back JPEG data with the capture metadata, so it goes through
/// the same processing as a photo from the library (capture time read, then metadata stripped).
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage,
               let data = Self.jpeg(image, metadata: info[.mediaMetadata] as? [String: Any] ?? [:]) {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        /// Writes the sensor image with its metadata (orientation, capture time).
        private static func jpeg(_ image: UIImage, metadata: [String: Any]) -> Data? {
            guard let cgImage = image.cgImage else { return nil }
            var properties = metadata
            // A photo taken just now: fill in the capture time if the camera didn't.
            var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            if exif[kCGImagePropertyExifDateTimeOriginal as String] == nil {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                exif[kCGImagePropertyExifDateTimeOriginal as String] = formatter.string(from: .now)
                properties[kCGImagePropertyExifDictionary as String] = exif
            }
            if properties[kCGImagePropertyOrientation as String] == nil {
                properties[kCGImagePropertyOrientation as String] = CGImagePropertyOrientation(image.imageOrientation).rawValue
            }

            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        }
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
