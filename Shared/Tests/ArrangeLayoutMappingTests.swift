#if os(macOS)
import XCTest
@testable import Quip

/// The phone speaks in user-facing language (`ArrangeLayout.horizontal` /
/// `ArrangeLayout.vertical`). The Mac's arrangement engine uses
/// `LayoutMode.columns` / `.rows`. These tests pin down the translation so
/// a typo at the boundary can't silently flip the arrangement axis.
/// (GH #20.)
final class ArrangeLayoutMappingTests: XCTestCase {

    func testHorizontalMapsToColumns() {
        XCTAssertEqual(LayoutMode.from(arrangeLayout: .horizontal), .columns,
                       "'horizontal' = windows side-by-side = columns")
    }

    func testVerticalMapsToRows() {
        XCTAssertEqual(LayoutMode.from(arrangeLayout: .vertical), .rows,
                       "'vertical' = windows stacked = rows")
    }

    func testArrangeLayoutEnumIsExhaustive() {
        // If a new ArrangeLayout case lands on the wire, this test forces
        // a deliberate update of `LayoutMode.from(arrangeLayout:)` and the
        // Mac handler — the enum-tighten work in GH #20 was specifically
        // to surface this as a build-fail rather than a silent dropped frame.
        XCTAssertEqual(ArrangeLayout.allCases, [.horizontal, .vertical],
                       "Wire enum is intentionally restricted to {horizontal, vertical} — see GH #20 + test_ArrangeWindowsWireEnumStillRejectsGrid")
    }

    func testLegacyStringOverloadStillWorks() {
        // The deprecated `fromArrangeLayout(_:)` String overload should
        // keep working until all callers migrate. This locks the
        // backward-compat path so a removal accident doesn't slip in.
        XCTAssertEqual(LayoutMode.fromArrangeLayout("horizontal"), .columns)
        XCTAssertEqual(LayoutMode.fromArrangeLayout("vertical"), .rows)
        XCTAssertNil(LayoutMode.fromArrangeLayout("grid"))
        XCTAssertNil(LayoutMode.fromArrangeLayout(""))
        XCTAssertNil(LayoutMode.fromArrangeLayout("HORIZONTAL"),
                     "Case-sensitive — the protocol string is canonical lowercase.")
    }
}
#endif
