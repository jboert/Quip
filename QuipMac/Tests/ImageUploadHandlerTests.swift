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
}
