import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Prepares a broadcast thumbnail: any image file, scaled to fit 1280 × 720
/// (YouTube's recommended size) and saved as a JPEG under YouTube's 2 MB limit.
public enum Thumbnail {
    public static let maxBytes = 2 * 1024 * 1024
    static let maxPixelSize = 1280

    public struct Failure: LocalizedError {
        public let errorDescription: String?
    }

    public static func jpegData(contentsOf url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw Failure(errorDescription: "Couldn't open \(url.lastPathComponent).")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure(errorDescription: "\(url.lastPathComponent) isn't an image Parallax can read.")
        }
        for quality in [0.9, 0.75, 0.6, 0.4] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { break }
            if data.length <= maxBytes { return data as Data }
        }
        throw Failure(errorDescription: "Couldn't make \(url.lastPathComponent) small enough for a thumbnail.")
    }
}
