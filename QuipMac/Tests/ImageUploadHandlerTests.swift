import XCTest
@testable import Quip

final class ImageUploadHandlerTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageUploadHandlerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_save_writesFileAndReturnsAbsolutePath() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let handler = ImageUploadHandler(uploadsDirectory: root)

        // 1x1 transparent PNG
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let msg = ImageUploadMessage(
            imageId: "abc-123",
            windowId: "w1",
            filename: "tiny.png",
            mimeType: "image/png",
            data: pngBase64
        )

        let savedURL = try handler.save(message: msg)

        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertTrue(savedURL.path.hasPrefix(resolvedRoot + "/"))
        XCTAssertTrue(savedURL.lastPathComponent.contains("abc-123"))
        XCTAssertTrue(savedURL.lastPathComponent.hasSuffix("tiny.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        let bytes = try Data(contentsOf: savedURL)
        XCTAssertEqual(bytes, Data(base64Encoded: pngBase64))
    }

    func test_save_throwsOnInvalidBase64() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let handler = ImageUploadHandler(uploadsDirectory: root)
        let msg = ImageUploadMessage(
            imageId: "bad",
            windowId: "w1",
            filename: "broken.png",
            mimeType: "image/png",
            data: "!!!not valid base64!!!"
        )

        XCTAssertThrowsError(try handler.save(message: msg))
    }

    func test_save_sanitizesFilenameToPreventPathTraversal() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let handler = ImageUploadHandler(uploadsDirectory: root)
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let msg = ImageUploadMessage(
            imageId: "x",
            windowId: "w1",
            filename: "../../evil.png",
            mimeType: "image/png",
            data: pngBase64
        )

        let savedURL = try handler.save(message: msg)
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedSaved = savedURL.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertTrue(
            resolvedSaved.hasPrefix(resolvedRoot + "/"),
            "Saved path escaped the uploads root: resolved=\(resolvedSaved) root=\(resolvedRoot)"
        )
    }

    func test_save_sanitizesImageIdToPreventPathTraversal() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let handler = ImageUploadHandler(uploadsDirectory: root)
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let msg = ImageUploadMessage(
            imageId: "../../../../tmp/quip-escape",
            windowId: "w1",
            filename: "evil.png",
            mimeType: "image/png",
            data: pngBase64
        )

        let savedURL = try handler.save(message: msg)
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedSaved = savedURL.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertTrue(
            resolvedSaved.hasPrefix(resolvedRoot + "/"),
            "imageId escape succeeded: resolved=\(resolvedSaved) root=\(resolvedRoot)"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: "/tmp/quip-escape-evil.png"),
            "A file escaped the sandbox and was written outside the uploads root"
        )
    }

    func test_save_dotDotInFilenameActuallyGetsReplaced() throws {
        // Guards against the `NSString.lastPathComponent`-strips-everything-first
        // false-negative in the existing traversal test.
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let handler = ImageUploadHandler(uploadsDirectory: root)
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let msg = ImageUploadMessage(
            imageId: "x",
            windowId: "w1",
            filename: "foo..bar..png",  // no leading `../` — survives lastPathComponent
            mimeType: "image/png",
            data: pngBase64
        )

        let savedURL = try handler.save(message: msg)
        XCTAssertFalse(
            savedURL.lastPathComponent.contains(".."),
            "sanitize() failed to strip `..` tokens: \(savedURL.lastPathComponent)"
        )
    }

    // MARK: - Magic-byte / mimeType validation

    func test_save_rejectsNonImagePayload() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let handler = ImageUploadHandler(uploadsDirectory: root)
        // 16 zero bytes — base64-decodes successfully, but isn't any known
        // image format. Stand-in for "phone uploaded a script / archive /
        // arbitrary binary blob and labelled it image/png."
        let zeros = Data(repeating: 0x00, count: 16).base64EncodedString()
        let msg = ImageUploadMessage(
            imageId: "x",
            windowId: "w1",
            filename: "fake.png",
            mimeType: "image/png",
            data: zeros
        )

        XCTAssertThrowsError(try handler.save(message: msg)) { error in
            guard case ImageUploadHandlerError.notAnImage = error else {
                XCTFail("expected .notAnImage, got \(error)")
                return
            }
        }
        // Nothing should have been written.
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(listing.isEmpty, "non-image payload still landed on disk: \(listing)")
    }

    func test_save_rejectsMimeTypeMismatch() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let handler = ImageUploadHandler(uploadsDirectory: root)
        // Real PNG bytes, but the wire claims it's a JPEG. A buggy or hostile
        // client should not be able to re-tag content under a different mime.
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let msg = ImageUploadMessage(
            imageId: "x",
            windowId: "w1",
            filename: "tiny.jpg",
            mimeType: "image/jpeg",
            data: pngBase64
        )

        XCTAssertThrowsError(try handler.save(message: msg)) { error in
            guard case ImageUploadHandlerError.mimeTypeMismatch(let detected, let declared) = error else {
                XCTFail("expected .mimeTypeMismatch, got \(error)")
                return
            }
            XCTAssertEqual(detected, .png)
            XCTAssertEqual(declared, "image/jpeg")
        }
    }

    func test_imageFormatDetect_recognizesPNG() {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                            0x00, 0x00, 0x00, 0x0D]
        XCTAssertEqual(ImageFormat.detect(from: Data(png)), .png)
    }

    func test_imageFormatDetect_recognizesJPEG() {
        // SOI + APP0 marker prefix is enough.
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46,
                             0x49, 0x46, 0x00, 0x01]
        XCTAssertEqual(ImageFormat.detect(from: Data(jpeg)), .jpeg)
    }

    func test_imageFormatDetect_recognizesGIF89a() {
        let gif = "GIF89a000000".data(using: .ascii)!
        XCTAssertEqual(ImageFormat.detect(from: gif), .gif)
    }

    func test_imageFormatDetect_recognizesWebP() {
        let webp: [UInt8] = [0x52, 0x49, 0x46, 0x46,  // RIFF
                             0x24, 0x00, 0x00, 0x00,  // size
                             0x57, 0x45, 0x42, 0x50]  // WEBP
        XCTAssertEqual(ImageFormat.detect(from: Data(webp)), .webp)
    }

    func test_imageFormatDetect_recognizesHEIC() {
        let heic: [UInt8] = [0x00, 0x00, 0x00, 0x18,
                             0x66, 0x74, 0x79, 0x70,  // ftyp
                             0x68, 0x65, 0x69, 0x63]  // brand: heic
        XCTAssertEqual(ImageFormat.detect(from: Data(heic)), .heic)
    }

    func test_imageFormatDetect_rejectsMP4() {
        // MP4 also has "ftyp" at offset 4 but a different brand. Must not
        // be misidentified as HEIC.
        let mp4: [UInt8] = [0x00, 0x00, 0x00, 0x18,
                            0x66, 0x74, 0x79, 0x70,
                            0x6D, 0x70, 0x34, 0x32]  // brand: mp42
        XCTAssertNil(ImageFormat.detect(from: Data(mp4)))
    }

    func test_imageFormatDetect_rejectsShortInput() {
        XCTAssertNil(ImageFormat.detect(from: Data([0x89, 0x50])))
        XCTAssertNil(ImageFormat.detect(from: Data()))
    }

    func test_imageFormat_matches_acceptsJpegAlias() {
        XCTAssertTrue(ImageFormat.jpeg.matches(mimeType: "image/jpeg"))
        XCTAssertTrue(ImageFormat.jpeg.matches(mimeType: "image/jpg"))
        XCTAssertTrue(ImageFormat.jpeg.matches(mimeType: "IMAGE/JPEG"))
        XCTAssertFalse(ImageFormat.jpeg.matches(mimeType: "image/png"))
    }

    func test_imageFormat_matches_heicAndHeifAreInterchangeable() {
        XCTAssertTrue(ImageFormat.heic.matches(mimeType: "image/heic"))
        XCTAssertTrue(ImageFormat.heic.matches(mimeType: "image/heif"))
    }
}
