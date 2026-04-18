import XCTest
import UIKit
@testable import Quip

final class ImageRecompressorTests: XCTestCase {

    /// Small PNG well under cap — must be returned unchanged.
    func test_smallImage_returnedUnchanged() throws {
        let image = UIImage.solidColor(.red, size: CGSize(width: 200, height: 200))
        let png = try XCTUnwrap(image.pngData())
        XCTAssertLessThan(png.count, 1_000_000)

        let recompressor = ImageRecompressor(maxPayloadBytes: 10_000_000)
        let result = try recompressor.recompress(rawData: png, declaredMime: "image/png")

        XCTAssertEqual(result.data, png)
        XCTAssertEqual(result.mimeType, "image/png")
    }

    /// Large image over cap — forced through JPEG re-encode / downscale.
    func test_largeImage_recompressedUnderCap() throws {
        let image = UIImage.solidColor(.blue, size: CGSize(width: 4000, height: 4000))
        let raw = try XCTUnwrap(image.pngData())

        // Tight cap forces the JPEG path even on a solid-color image.
        let recompressor = ImageRecompressor(maxPayloadBytes: 200_000)
        let result = try recompressor.recompress(rawData: raw, declaredMime: "image/png")

        XCTAssertLessThanOrEqual(result.data.count, 200_000)
        XCTAssertEqual(result.mimeType, "image/jpeg")
    }

    /// Cap so tight even a 512px JPEG can't fit — must throw.
    func test_impossibleCap_throws() throws {
        let image = UIImage.solidColor(.green, size: CGSize(width: 4000, height: 4000))
        let raw = try XCTUnwrap(image.pngData())

        let recompressor = ImageRecompressor(maxPayloadBytes: 100) // way too small
        XCTAssertThrowsError(try recompressor.recompress(rawData: raw, declaredMime: "image/png"))
    }

    /// Non-image bytes must throw `.decodeFailed` when recompression is needed.
    func test_undecodableBytes_throws() {
        let garbage = Data(repeating: 0x7F, count: 1_000_000)  // > typical cap
        let recompressor = ImageRecompressor(maxPayloadBytes: 100_000)
        XCTAssertThrowsError(try recompressor.recompress(rawData: garbage, declaredMime: "image/png"))
    }
}

private extension UIImage {
    static func solidColor(_ color: UIColor, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
