import XCTest
@testable import Quip

final class WindowColorTests: XCTestCase {

    func testNormalizedAcceptsHexWithOrWithoutHashAndUppercases() {
        XCTAssertEqual(WindowColor.normalized("#4a90d9"), "#4A90D9")
        XCTAssertEqual(WindowColor.normalized("  4A90D9\n"), "#4A90D9")
    }

    func testNormalizedRejectsAnythingButSixHexDigits() {
        for bad in ["", "#", "#FFF", "#FFFFFFF", "#GG0000", "red", "#12 456"] {
            XCTAssertNil(WindowColor.normalized(bad), bad)
        }
    }

    func testHexRoundsAndClampsComponents() {
        XCTAssertEqual(WindowColor.hex(red: 1, green: 0, blue: 0.5), "#FF0080")
        // Wide-gamut picker colors come back outside 0...1.
        XCTAssertEqual(WindowColor.hex(red: 1.2, green: -0.1, blue: .nan), "#FF0000")
    }

    func testEveryPaletteColorIsAlreadyNormalized() {
        for hex in WindowColor.palette {
            XCTAssertEqual(WindowColor.normalized(hex), hex)
        }
    }

    func testSetColorMessageRoundTrips() throws {
        let data = try XCTUnwrap(MessageCoder.encode(SetColorMessage(windowId: "w1", color: "#4A90D9")))
        let restored = try XCTUnwrap(MessageCoder.decode(SetColorMessage.self, from: data))
        XCTAssertEqual(restored.type, "set_color")
        XCTAssertEqual(restored.windowId, "w1")
        XCTAssertEqual(restored.color, "#4A90D9")
    }

    /// nil is "go back to automatic", and must survive the trip as nil rather
    /// than failing to decode.
    func testSetColorMessageCarriesReset() throws {
        let data = try XCTUnwrap(MessageCoder.encode(SetColorMessage(windowId: "w1", color: nil)))
        let restored = try XCTUnwrap(MessageCoder.decode(SetColorMessage.self, from: data))
        XCTAssertNil(restored.color)
    }
}
