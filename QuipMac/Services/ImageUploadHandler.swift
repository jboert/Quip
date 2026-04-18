import Foundation

enum ImageUploadHandlerError: Error {
    case invalidBase64
    case invalidPath
    case writeFailed(underlying: Error)
}

/// Decodes an ImageUploadMessage and writes it to disk in a sandboxed uploads directory.
/// Both `imageId` and `filename` from the wire are sanitized and the resolved target
/// path is verified to be inside the uploads directory — a malicious phone cannot
/// escape the uploads root via path traversal in either field.
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
