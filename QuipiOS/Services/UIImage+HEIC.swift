import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

extension UIImage {

    /// Encode the image as HEIC via ImageIO. Returns nil on platforms or
    /// color spaces that the system encoder can't represent. Quality is 0-1.
    ///
    /// HEIC at quality 0.85 is typically 50-70% smaller than the equivalent
    /// JPEG, preserves alpha, and is the format the iPhone camera roll
    /// already uses by default — re-encoding a camera-roll photo through
    /// this path is essentially a quality round-trip rather than a format
    /// conversion. The Mac side accepts HEIC via the magic-byte sniff in
    /// QuipMac/Services/ImageUploadHandler.swift:16,40,67 — no protocol or
    /// server change needed; just send `image/heic` as the mimeType field.
    ///
    /// WebP would have been the obvious pick (better compression, no Apple
    /// licensing) but the WebP encoder via CGImageDestination wasn't shipped
    /// until iOS 18; the project ships to iOS 17. HEIC encode has been
    /// available since iOS 11.
    func heicData(quality: CGFloat = 0.85) -> Data? {
        guard let cgImage = self.cgImage else { return nil }
        let mutableData = NSMutableData()
        let utType = UTType.heic.identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, utType, 1, nil
        ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
