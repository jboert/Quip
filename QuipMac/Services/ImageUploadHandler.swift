import Foundation

enum ImageUploadHandlerError: Error {
    case invalidBase64
    case invalidPath
    case notAnImage
    case mimeTypeMismatch(detected: ImageFormat, declared: String)
    case writeFailed(underlying: Error)
}

/// Decoded image formats we'll accept on the wire. The phone's recompressor
/// outputs JPEG; the photo picker can pass PNG or HEIC through unchanged when
/// the file is already small enough. GIF and WebP are accepted for emoji /
/// animated stickers.
enum ImageFormat: String {
    case png, jpeg, gif, webp, heic

    /// Detect the image format from the leading bytes of a decoded payload.
    /// Returns `nil` for anything that doesn't sniff as a known image —
    /// random binary blobs, scripts, archives, etc. all land here.
    static func detect(from bytes: Data) -> ImageFormat? {
        // 12 bytes is enough to disambiguate every format we accept.
        guard bytes.count >= 12 else { return nil }
        let b = [UInt8](bytes.prefix(12))

        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47,
           b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A {
            return .png
        }
        // JPEG: FF D8 FF (SOI marker + start of an APP segment)
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF {
            return .jpeg
        }
        // GIF: "GIF87a" or "GIF89a"
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38,
           b[4] == 0x37 || b[4] == 0x39, b[5] == 0x61 {
            return .gif
        }
        // WebP: "RIFF" <size:4> "WEBP"
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 {
            return .webp
        }
        // HEIC/HEIF: "ftyp" box at offset 4, with a HEIF brand at offset 8.
        // Any ISOBMFF file (MP4, MOV, etc.) has "ftyp" at the same offset, so
        // the brand check is what makes this an *image* not a video.
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = String(bytes: Array(b[8..<12]), encoding: .ascii) ?? ""
            // heic/heix = main HEIF still profiles. mif1/msf1 = HEIF image
            // collection brands. heim/heis = sequence brands seen on iPhones.
            if ["heic", "heix", "heim", "heis", "mif1", "msf1"].contains(brand) {
                return .heic
            }
        }
        return nil
    }

    /// True when this detected format is consistent with the wire-declared
    /// `mimeType`. `image/jpg` is folded into `image/jpeg` for tolerance.
    func matches(mimeType: String) -> Bool {
        let mt = mimeType.lowercased()
        switch self {
        case .png:  return mt == "image/png"
        case .jpeg: return mt == "image/jpeg" || mt == "image/jpg"
        case .gif:  return mt == "image/gif"
        case .webp: return mt == "image/webp"
        case .heic: return mt == "image/heic" || mt == "image/heif"
        }
    }
}

/// Decodes an ImageUploadMessage and writes it to disk in a sandboxed uploads directory.
/// Both `imageId` and `filename` from the wire are sanitized and the resolved target
/// path is verified to be inside the uploads directory — a malicious phone cannot
/// escape the uploads root via path traversal in either field. Decoded bytes
/// must also sniff as a known image format AND match the claimed `mimeType` —
/// random binary payloads (scripts, archives, executables) are rejected before
/// reaching disk.
struct ImageUploadHandler {

    /// Directory into which uploaded images are written. In production this is
    /// ~/Library/Caches/Quip/uploads/; tests pass a tempdir.
    let uploadsDirectory: URL

    /// Default production initializer.
    static func defaultProduction() -> ImageUploadHandler {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("Quip/uploads", isDirectory: true)
        return ImageUploadHandler(uploadsDirectory: dir)
    }

    /// Decode the base64 payload, write it to disk, and return the absolute URL.
    /// Filename in the returned URL has the form `<sanitizedImageId>-<sanitizedFilename>`.
    func save(message: ImageUploadMessage) throws -> URL {
        guard let bytes = Data(base64Encoded: message.data) else {
            throw ImageUploadHandlerError.invalidBase64
        }

        // Magic-byte sniff before anything else hits disk. Two checks:
        //   1. Bytes look like an image at all.
        //   2. The detected format is consistent with the declared mimeType.
        // Together these reject "I'm uploading a JPEG" → script.sh and "this is
        // an image (mimeType=image/png)" → arbitrary binary blob.
        guard let format = ImageFormat.detect(from: bytes) else {
            throw ImageUploadHandlerError.notAnImage
        }
        guard format.matches(mimeType: message.mimeType) else {
            throw ImageUploadHandlerError.mimeTypeMismatch(detected: format, declared: message.mimeType)
        }

        try FileManager.default.createDirectory(at: uploadsDirectory, withIntermediateDirectories: true)

        // Sanitize BOTH imageId and filename — either can carry `../` injection.
        let safeId = sanitize(component: message.imageId)
        let safeName = sanitize(component: message.filename)
        let target = uploadsDirectory.appendingPathComponent("\(safeId)-\(safeName)")

        // Defense in depth: verify the resolved target actually lies inside the
        // uploads root. `appendingPathComponent` does NOT canonicalize `..`, so a
        // prefix check on the un-resolved path is insufficient.
        let resolvedTarget = target.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedRoot = uploadsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedTarget.path.hasPrefix(resolvedRoot.path + "/") else {
            throw ImageUploadHandlerError.invalidPath
        }

        do {
            try bytes.write(to: resolvedTarget, options: .atomic)
        } catch {
            throw ImageUploadHandlerError.writeFailed(underlying: error)
        }
        return resolvedTarget
    }

    /// Reduce an arbitrary wire string to a safe single filename component.
    /// Strip path separators and parent-directory tokens; fall back to "file" if
    /// the result is empty.
    private func sanitize(component: String) -> String {
        let lastComponent = (component as NSString).lastPathComponent
        var filtered = lastComponent.replacingOccurrences(of: "/", with: "_")
                                    .replacingOccurrences(of: "\\", with: "_")
        // Collapse any remaining `..` tokens (including ones that re-emerge after
        // `/` replacement like `..foo..`). Loop until stable.
        while filtered.contains("..") {
            filtered = filtered.replacingOccurrences(of: "..", with: "_")
        }
        return filtered.isEmpty ? "file" : filtered
    }
}
