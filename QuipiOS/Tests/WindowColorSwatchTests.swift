import XCTest
@testable import Quip

/// The card menu's Color strip (Q-61): every palette entry has a spoken name,
/// and the swatch images are real colored bitmaps, not template symbols.
final class WindowColorSwatchTests: XCTestCase {

    func test_everyPaletteColorHasADistinctName() {
        var seen: Set<String> = []
        for hex in WindowColor.palette {
            let name = WindowColorSwatch.name(for: hex)
            XCTAssertNotEqual(name, hex, "\(hex) has no name")
            XCTAssertTrue(seen.insert(name).inserted, "\(name) is used twice")
        }
        XCTAssertEqual(WindowColorSwatch.name(for: "d0021b"), "Red", "lookup normalizes the hex")
        XCTAssertEqual(WindowColorSwatch.name(for: "#123456"), "#123456", "a custom color falls back to its hex")
    }

    func test_swatchImage_isOriginalRenderingAndColored() {
        let image = WindowColorSwatch.image(hex: "#D0021B", selected: false)
        XCTAssertEqual(image.renderingMode, .alwaysOriginal, "a template image would draw in the menu's text color")
        XCTAssertEqual(image.size, CGSize(width: 22, height: 22))
        let selected = WindowColorSwatch.image(hex: "#D0021B", selected: true)
        XCTAssertNotEqual(selected.pngData(), image.pngData(), "the selected swatch carries a check mark")
    }
}
