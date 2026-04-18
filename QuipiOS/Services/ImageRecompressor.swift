import Foundation
import UIKit

enum ImageRecompressorError: Error {
    case decodeFailed
    case cannotFitUnderCap
}

/// Ensures an image's byte count fits under a configurable cap.
/// Called before base64 encoding; the caller reserves headroom for base64's
/// ~33% inflation (e.g., pass `10_000_000 / 1.37 ≈ 7_300_000` for a 10 MB
/// post-base64 cap).
struct ImageRecompressor {

    /// Post-recompression byte budget.
    let maxPayloadBytes: Int

    /// Longest-edge pixel floor. Images are never downscaled below this.
    let minLongestEdge: CGFloat = 512

    /// Scale factor per downscale iteration (25% shrink).
    let downscaleStep: CGFloat = 0.75

    /// JPEG quality for recompress path.
    let jpegQuality: CGFloat = 0.85

    /// Returns bytes to send + the mime type that matches them (may change
    /// from `image/png` to `image/jpeg`).
    func recompress(rawData: Data, declaredMime: String) throws -> (data: Data, mimeType: String) {
        if rawData.count <= maxPayloadBytes {
            return (rawData, declaredMime)
        }

        guard var image = UIImage(data: rawData) else {
            throw ImageRecompressorError.decodeFailed
        }

        // First: re-encode at jpegQuality without resizing.
        if let jpeg = image.jpegData(compressionQuality: jpegQuality), jpeg.count <= maxPayloadBytes {
            return (jpeg, "image/jpeg")
        }

        // Then: progressively downscale until it fits or we hit the floor.
        var longest = max(image.size.width, image.size.height)
        while longest > minLongestEdge {
            longest *= downscaleStep
            let scale = longest / max(image.size.width, image.size.height)
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            // Pin renderer scale to 1 so the backing bitmap matches newSize in
            // pixels. Without this the renderer picks up the screen scale
            // (2x/3x), silently inflating the bitmap and the downstream JPEG
            // encode — so the "downscale" step would shrink far less than the
            // point-size math suggests on a real device.
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
            image = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
            if let jpeg = image.jpegData(compressionQuality: jpegQuality), jpeg.count <= maxPayloadBytes {
                return (jpeg, "image/jpeg")
            }
        }

        throw ImageRecompressorError.cannotFitUnderCap
    }
}
