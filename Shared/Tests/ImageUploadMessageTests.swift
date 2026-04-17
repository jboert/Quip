import XCTest
@testable import Quip

/// Unit tests for ImageUploadMessage, ImageUploadAckMessage, ImageUploadErrorMessage.
/// Mirrors the patterns used in MessageProtocolTests.swift for consistency.
final class ImageUploadMessageTests: XCTestCase {

    // MARK: - Outgoing (iPhone → Mac)

    func testImageUploadMessageEncoding() throws {
        let msg = ImageUploadMessage(
            imageId: "550e8400-e29b-41d4-a716-446655440000",
            windowId: "window-abc-123",
            filename: "screenshot-2026-04-16.png",
            mimeType: "image/png",
            data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let dict = try jsonDict(from: data)

        XCTAssertEqual(dict["type"] as? String, "image_upload")
        XCTAssertEqual(dict["imageId"] as? String, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(dict["windowId"] as? String, "window-abc-123")
        XCTAssertEqual(dict["filename"] as? String, "screenshot-2026-04-16.png")
        XCTAssertEqual(dict["mimeType"] as? String, "image/png")
        XCTAssertNotNil(dict["data"])
    }

    func testImageUploadMessageRoundTrip() throws {
        let original = ImageUploadMessage(
            imageId: "abc-123",
            windowId: "win-1",
            filename: "tiny.png",
            mimeType: "image/png",
            data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )
        let encoded = try XCTUnwrap(MessageCoder.encode(original))
        XCTAssertEqual(MessageCoder.messageType(from: encoded), "image_upload")

        let decoded = try XCTUnwrap(MessageCoder.decode(ImageUploadMessage.self, from: encoded))
        XCTAssertEqual(decoded.imageId, original.imageId)
        XCTAssertEqual(decoded.windowId, original.windowId)
        XCTAssertEqual(decoded.filename, original.filename)
        XCTAssertEqual(decoded.mimeType, original.mimeType)
        XCTAssertEqual(decoded.data, original.data)
    }

    // MARK: - Incoming (Mac → iPhone)

    func testImageUploadAckMessageEncoding() throws {
        let msg = ImageUploadAckMessage(
            imageId: "abc-123",
            savedPath: "/Users/alice/Library/Caches/Quip/uploads/abc-123-screenshot.png"
        )
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let dict = try jsonDict(from: data)

        XCTAssertEqual(dict["type"] as? String, "image_upload_ack")
        XCTAssertEqual(dict["imageId"] as? String, "abc-123")
        XCTAssertEqual(dict["savedPath"] as? String, "/Users/alice/Library/Caches/Quip/uploads/abc-123-screenshot.png")
    }

    func testImageUploadErrorMessageEncoding() throws {
        let msg = ImageUploadErrorMessage(imageId: "abc-123", reason: "unknown window")
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let dict = try jsonDict(from: data)

        XCTAssertEqual(dict["type"] as? String, "image_upload_error")
        XCTAssertEqual(dict["imageId"] as? String, "abc-123")
        XCTAssertEqual(dict["reason"] as? String, "unknown window")
    }

    // MARK: - Helpers

    private func jsonDict(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
