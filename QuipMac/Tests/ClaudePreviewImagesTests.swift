import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Quip

final class ClaudePreviewImagesTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cpi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func writeImage(_ name: String, width: Int, height: Int, type: UTType) throws -> String {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    func test_pngIsSentAsItsOwnBytes() throws {
        let path = try writeImage("shot.png", width: 1290, height: 2796, type: .png)
        let msg = ClaudePreviewImages.fullImage(path: path, id: "A")
        XCTAssertNil(msg.error)
        XCTAssertEqual(msg.format, "png")
        XCTAssertEqual(msg.pixelWidth, 1290)
        XCTAssertEqual(msg.pixelHeight, 2796)
        XCTAssertEqual(Data(base64Encoded: msg.data), FileManager.default.contents(atPath: path))
    }

    func test_tiffBecomesFullSizeJPEG() throws {
        let path = try writeImage("shot.tiff", width: 800, height: 600, type: .tiff)
        let msg = ClaudePreviewImages.fullImage(path: path, id: "A")
        XCTAssertEqual(msg.format, "jpeg")
        XCTAssertEqual(msg.pixelWidth, 800)
        XCTAssertFalse(msg.data.isEmpty)
    }

    func test_thumbnailIsSmall() throws {
        let path = try writeImage("shot.png", width: 1290, height: 2796, type: .png)
        let thumb = try XCTUnwrap(ClaudePreviewImages.thumbnail(path: path))
        let data = try XCTUnwrap(Data(base64Encoded: thumb))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual(props[kCGImagePropertyPixelHeight] as? Int ?? .max, ClaudePreviewImages.thumbnailMaxPixel)
    }

    func test_missingFileIsAnError() {
        let msg = ClaudePreviewImages.fullImage(path: dir.appendingPathComponent("nope.png").path, id: "A")
        XCTAssertNotNil(msg.error)
        XCTAssertEqual(msg.data, "")
    }

    func test_tunnelMayNotSendPreviewMessages() {
        for type in ["claude_preview_request", "claude_preview_dismiss", "set_claude_previews"] {
            XCTAssertEqual(WebSocketServer.refusedTunnelType(in: Data(#"{"type":"\#(type)","id":"A"}"#.utf8)), type)
        }
        XCTAssertNil(WebSocketServer.refusedTunnelType(in: Data(#"{"type":"send_text"}"#.utf8)))
    }
}
