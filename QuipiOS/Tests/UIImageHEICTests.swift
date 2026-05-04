import XCTest
import UIKit
@testable import Quip

final class UIImageHEICTests: XCTestCase {

    /// HEIC files are ISO base-media containers; the magic is the `ftyp`
    /// box at byte offset 4. Mac's ImageUploadHandler sniffs this to
    /// identify the format, so the magic bytes must be intact.
    func test_heicData_producesValidFtypHeader() throws {
        let image = UIImage.solidColor(.red, size: CGSize(width: 256, height: 256))
        let data = try XCTUnwrap(image.heicData(quality: 0.85),
                                 "HEIC encoder should be available on iOS 11+ on supported hardware")
        XCTAssertGreaterThanOrEqual(data.count, 12, "HEIC header is at least 12 bytes")
        let ftypBytes = Array(data[4..<8])
        XCTAssertEqual(ftypBytes, Array("ftyp".utf8), "ftyp box marker at offset 4")
    }

    /// HEIC must beat JPEG-0.95 on a noisy gradient (which is closer to
    /// realistic photo content than a solid color, where both compressors
    /// trivialize the work).
    func test_heicData_smallerThanJpegForPhotoContent() throws {
        let image = noisyGradient(size: CGSize(width: 1024, height: 1024))
        let heic = try XCTUnwrap(image.heicData(quality: 0.85))
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.95))

        XCTAssertLessThan(heic.count, jpeg.count,
                          "HEIC@0.85 should beat JPEG@0.95 (got \(heic.count) vs \(jpeg.count))")
    }

    private func noisyGradient(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            for x in stride(from: 0, to: Int(size.width), by: 1) {
                for y in stride(from: 0, to: Int(size.height), by: 1) {
                    let h = CGFloat(x) / size.width
                    let s = CGFloat(y) / size.height
                    let jitter = CGFloat.random(in: -0.05...0.05)
                    UIColor(hue: h, saturation: max(0, min(1, s + jitter)),
                            brightness: 0.7, alpha: 1).setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
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
