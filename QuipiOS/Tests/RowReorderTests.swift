import XCTest
@testable import Quip

/// Hold-and-drag reordering of the button rows (Q-65): the pure slot maths
/// and the persisted main-row order.
final class RowReorderTests: XCTestCase {

    private let frames: [String: CGRect] = [
        "a": CGRect(x: 0, y: 0, width: 40, height: 40),     // mid 20
        "b": CGRect(x: 50, y: 0, width: 40, height: 40),    // mid 70
        "c": CGRect(x: 100, y: 0, width: 40, height: 40),   // mid 120
    ]

    func test_targetIndex_countsCentresPassed() {
        let order = ["a", "b", "c"]
        XCTAssertEqual(RowReorderMath.targetIndex(order: order, dragging: "a", centerX: 20, frames: frames), 0)
        XCTAssertEqual(RowReorderMath.targetIndex(order: order, dragging: "a", centerX: 80, frames: frames), 1, "past b's centre")
        XCTAssertEqual(RowReorderMath.targetIndex(order: order, dragging: "a", centerX: 130, frames: frames), 2, "past c's centre")
        XCTAssertEqual(RowReorderMath.targetIndex(order: order, dragging: "c", centerX: 10, frames: frames), 0)
        XCTAssertEqual(RowReorderMath.targetIndex(order: order, dragging: "c", centerX: 60, frames: frames), 1,
                       "an item with no frame is skipped")
        XCTAssertEqual(RowReorderMath.targetIndex(order: ["a", "x", "b"], dragging: "a", centerX: 80, frames: frames), 1)
    }

    func test_move() {
        XCTAssertEqual(RowReorderMath.move(["a", "b", "c"], id: "a", to: 2), ["b", "c", "a"])
        XCTAssertEqual(RowReorderMath.move(["a", "b", "c"], id: "c", to: 0), ["c", "a", "b"])
        XCTAssertEqual(RowReorderMath.move(["a", "b", "c"], id: "b", to: 9), ["a", "c", "b"], "clamped")
        XCTAssertEqual(RowReorderMath.move(["a", "b", "c"], id: "b", to: 1), ["a", "b", "c"], "no-op stays put")
    }

    func test_mainRowOrder_roundTripAndRepair() {
        XCTAssertEqual(MainRowOrder.decode(""), MainRowOrder.defaultOrder)
        XCTAssertEqual(MainRowOrder.decode("not json"), MainRowOrder.defaultOrder)
        let moved = RowReorderMath.move(MainRowOrder.defaultOrder, id: MainRowOrder.return, to: 0)
        XCTAssertEqual(MainRowOrder.decode(MainRowOrder.encode(moved)), moved)
        // An older save that predates the broadcast tile and holds junk.
        let old = MainRowOrder.encode(["return", "bogus", "mic", "spawn", "return"])
        let repaired = MainRowOrder.decode(old)
        XCTAssertEqual(repaired.filter { $0 == "return" }.count, 1, "duplicates removed")
        XCTAssertFalse(repaired.contains("bogus"))
        XCTAssertEqual(Set(repaired), Set(MainRowOrder.defaultOrder), "every button is present")
        let micAt = repaired.firstIndex(of: "mic")!
        XCTAssertLessThan(repaired.firstIndex(of: "cycleLeft")!, micAt, "a left-of-mic default stays left of the mic")
        XCTAssertGreaterThan(repaired.firstIndex(of: "broadcast")!, micAt, "a right-of-mic default stays right")
        XCTAssertEqual(repaired.prefix(1), ["return"], "the saved order is kept")
    }

    func test_mainRowSizes_fitShrinksOnlyWhenNeeded() {
        let sizes = MainRowSizes(navW: 24, navH: 36, btnW: 48, btnH: 56, auxW: 36, auxH: 56, pttW: 56)
        let all = MainRowOrder.defaultOrder
        // Tiles 24+24+36+36 | 56 | 30+48+36+36+48 = 374; left 3 gaps + right 4 gaps = 42; mic gaps 16.
        XCTAssertEqual(sizes.naturalWidth(for: all), 374 + 42 + 16)
        XCTAssertEqual(sizes.fitted(to: 440, visible: all), sizes, "fits: untouched")
        let tight = sizes.fitted(to: 340, visible: all)
        XCTAssertLessThanOrEqual(tight.naturalWidth(for: all), 340)
        XCTAssertEqual(tight.btnH, 56, "heights never change")
        XCTAssertGreaterThan(tight.btnW, tight.auxW, "proportions are kept")
        let few = [MainRowOrder.mic, MainRowOrder.return]
        XCTAssertEqual(sizes.fitted(to: 200, visible: few), sizes, "a short row needs no shrinking")
        XCTAssertGreaterThanOrEqual(sizes.fitted(to: 10, visible: all).btnW, 28, "never below 60 %")
    }
}
