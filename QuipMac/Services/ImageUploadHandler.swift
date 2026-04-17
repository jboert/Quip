import Foundation

enum ImageUploadHandlerError: Error {
    case invalidBase64
    case writeFailed(underlying: Error)
}

/// Decodes an ImageUploadMessage and writes it to disk in a sandboxed uploads directory.
/// Filename is sanitized so a malicious phone can't write outside the uploads directory.
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
    /// Filename in the returned URL has the form `<imageId>-<sanitizedFilename>`.
    func save(message: ImageUploadMessage) throws -> URL {
        guard let bytes = Data(base64Encoded: message.data) else {
            throw ImageUploadHandlerError.invalidBase64
        }

        try FileManager.default.createDirectory(at: uploadsDirectory, withIntermediateDirectories: true)

        let safeName = sanitize(filename: message.filename)
        let target = uploadsDirectory.appendingPathComponent("\(message.imageId)-\(safeName)")

        do {
            try bytes.write(to: target, options: .atomic)
        } catch {
            throw ImageUploadHandlerError.writeFailed(underlying: error)
        }
        return target
    }

    /// Strip path separators and parent-directory tokens. Keep it simple and strict.
    private func sanitize(filename: String) -> String {
        let lastComponent = (filename as NSString).lastPathComponent
        let filtered = lastComponent.replacingOccurrences(of: "/", with: "_")
                                    .replacingOccurrences(of: "\\", with: "_")
                                    .replacingOccurrences(of: "..", with: "_")
        return filtered.isEmpty ? "image" : filtered
    }
}
