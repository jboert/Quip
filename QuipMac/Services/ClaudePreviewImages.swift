import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Thumbnails and full images of the files Claude opened (Q-87). All
/// nonisolated and synchronous; callers run them off the main actor.
enum ClaudePreviewImages {
    static let thumbnailMaxPixel = 240

    /// Largest raw payload that still fits one WebSocket message once
    /// base64-encoded (4/3) with room for the JSON around it.
    static let maxRawBytes = WSLimits.maxMessageBytes / 4 * 3 - 256 * 1024

    static func isPDF(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "pdf"
    }

    /// Base64 JPEG, ~240 px on the long edge. Nil when the file can't be read.
    static func thumbnail(path: String) -> String? {
        guard let image = isPDF(path) ? pdfFirstPage(path: path, maxPixel: thumbnailMaxPixel * 2)?.image
                                      : downscaled(path: path, maxPixel: thumbnailMaxPixel) else { return nil }
        let fitted = image.width > thumbnailMaxPixel || image.height > thumbnailMaxPixel
            ? resized(image, maxPixel: thumbnailMaxPixel) ?? image : image
        return jpeg(fitted, quality: 0.7)?.base64EncodedString()
    }

    /// The full image for the phone's viewer. A PNG or JPEG that fits is sent
    /// as its own bytes, so zooming shows the real pixels. Anything else (or
    /// too large) becomes a JPEG at full size, stepped down until it fits.
    static func fullImage(path: String, id: String) -> ClaudePreviewImageMessage {
        func failure(_ reason: String) -> ClaudePreviewImageMessage {
            ClaudePreviewImageMessage(id: id, format: "jpeg", data: "", pixelWidth: 0, pixelHeight: 0, error: reason)
        }
        if isPDF(path) {
            guard let page = pdfFirstPage(path: path, maxPixel: 4096) else { return failure("Couldn't read the PDF") }
            guard let (data, w, h) = fittingJPEG(page.image) else { return failure("The PDF page is too large to send") }
            return ClaudePreviewImageMessage(id: id, format: "jpeg", data: data.base64EncodedString(),
                                             pixelWidth: w, pixelHeight: h, pageCount: page.pageCount)
        }
        guard let data = FileManager.default.contents(atPath: path) else { return failure("The file is gone") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else { return failure("Not an image Quip can read") }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0

        let passThrough: String? = type == UTType.png.identifier ? "png"
            : type == UTType.jpeg.identifier ? "jpeg" : nil
        if let format = passThrough, data.count <= maxRawBytes, width > 0 {
            return ClaudePreviewImageMessage(id: id, format: format, data: data.base64EncodedString(),
                                             pixelWidth: width, pixelHeight: height)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return failure("Not an image Quip can read") }
        guard let (jpegData, w, h) = fittingJPEG(image) else { return failure("The image is too large to send") }
        return ClaudePreviewImageMessage(id: id, format: "jpeg", data: jpegData.base64EncodedString(),
                                         pixelWidth: w, pixelHeight: h)
    }

    // MARK: - Helpers

    /// JPEG q0.9 at full size; if over `maxRawBytes`, 75 % smaller each step.
    private static func fittingJPEG(_ image: CGImage) -> (Data, Int, Int)? {
        var current = image
        for _ in 0..<8 {
            if let data = jpeg(current, quality: 0.9), data.count <= maxRawBytes {
                return (data, current.width, current.height)
            }
            let next = Int(Double(max(current.width, current.height)) * 0.75)
            guard next >= 256, let smaller = resized(current, maxPixel: next) else { return nil }
            current = smaller
        }
        return nil
    }

    private static func downscaled(path: String, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }

    private static func resized(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let scale = Double(maxPixel) / Double(max(image.width, image.height))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Page 1 rendered at 2× its point size, capped at `maxPixel`, on white.
    private static func pdfFirstPage(path: String, maxPixel: Int) -> (image: CGImage, pageCount: Int)? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), let page = doc.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(2.0, Double(maxPixel) / Double(max(box.width, box.height)))
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let image = ctx.makeImage() else { return nil }
        return (image, doc.pageCount)
    }
}
