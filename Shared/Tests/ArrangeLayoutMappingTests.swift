#if os(macOS)
import XCTest
@testable import Quip

/// The phone speaks in user-facing language ("horizontal", "vertical"). The
/// Mac's arrangement engine uses `LayoutMode.columns` / `.rows`. These tests
/// pin down the translation so a typo at the boundary can't silently flip
/// the arrangement axis.
final class ArrangeLayoutMappingTests: XCTestCase {

    func testHorizontalMapsToColumns() {
        XCTAssertEqual(LayoutMode.fromArrangeLayout("horizontal"), .columns,
                       "'horizontal' = windows side-by-side = columns")
    }

    func testVerticalMapsToRows() {
        XCTAssertEqual(LayoutMode.fromArrangeLayout("vertical"), .rows,
                       "'vertical' = windows stacked = rows")
    }

    func testUnknownLayoutReturnsNil() {
        XCTAssertNil(LayoutMode.fromArrangeLayout("grid"),
                     "The arrange_windows protocol only supports horizontal/vertical today; other names must reject, not silently pick a default.")
        XCTAssertNil(LayoutMode.fromArrangeLayout(""))
        XCTAssertNil(LayoutMode.fromArrangeLayout("HORIZONTAL"),
                     "Case-sensitive — the protocol string is canonical lowercase.")
    }
}
#endif
