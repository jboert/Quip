import XCTest
@testable import Quip

/// Settings and the main window's popover both render through `PairingQR`,
/// off the main actor, instead of each running its own CIFilter in a view body.
final class PairingQRTests: XCTestCase {

    func test_pairLink_rendersAtLeastAVersion1Code() throws {
        let image = try XCTUnwrap(PairingQR.image(for: "quip://pair?url=abc&pin=11112222"))
        // A version-1 QR is 21 modules wide; the image is one point per module.
        XCTAssertGreaterThanOrEqual(image.size.width, 21)
    }

    func test_emptyContent_rendersNothing() {
        XCTAssertNil(PairingQR.image(for: ""))
    }
}
