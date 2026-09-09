import XCTest
@testable import Quip

/// Multi-display geometry. Before this existed, `broadcastLayout` normalized
/// EVERY window against one display, so on a two-monitor desk (a Mac Studio
/// with the terminal parked on the second screen) the phone got frames the
/// canvas can't contain:
///
///   focus on primary:    second-screen window -> x = 1.047   (off-canvas)
///   focus on 2nd screen: primary window       -> x = -1.266  (off-canvas)
///
/// Worse, "which display" was `NSScreen.main` — the *focused* screen — so
/// clicking the other monitor silently re-based every window's coordinates.
///
/// These tests use the real measurements from the reporting desk: a 3440x1440
/// ultrawide as primary with a 2560x1440 monitor to its right.
final class DisplayGeometryTests: XCTestCase {

    private let primary = DisplayRect(x: 0, y: 0, width: 3440, height: 1440)
    private let secondary = DisplayRect(x: 3440, y: 0, width: 2560, height: 1440)

    private var displays: [(id: String, isPrimary: Bool, rect: DisplayRect)] {
        [(id: "d-primary", isPrimary: true, rect: primary),
         (id: "d-second", isPrimary: false, rect: secondary)]
    }

    /// A frame the phone's canvas can actually draw: fully inside 0-1.
    private func assertOnCanvas(_ frame: WindowFrame, _ message: String) {
        XCTAssertGreaterThanOrEqual(frame.x, 0, message)
        XCTAssertGreaterThanOrEqual(frame.y, 0, message)
        XCTAssertLessThanOrEqual(frame.x + frame.width, 1.0001, message)
        XCTAssertLessThanOrEqual(frame.y + frame.height, 1.0001, message)
    }

    // MARK: - The regression

    func testSecondScreenWindowLandsOnCanvasWhenNormalizedAgainstItsOwnDisplay() {
        // A terminal on the second monitor, in CG coordinates.
        let terminal = DisplayRect(x: 3600, y: 200, width: 1200, height: 800)

        let wrong = DisplayGeometry.normalize(window: terminal, on: primary)
        XCTAssertGreaterThan(wrong.x, 1.0,
                             "the old single-display normalization put it past the right edge")

        let right = DisplayGeometry.normalize(window: terminal, on: secondary)
        assertOnCanvas(right, "normalized against its own display it must be drawable")
        XCTAssertEqual(right.x, 160.0 / 2560.0, accuracy: 0.0001)
        XCTAssertEqual(right.width, 1200.0 / 2560.0, accuracy: 0.0001)
    }

    func testPrimaryWindowIsUnaffectedByTheSecondScreen() {
        // Back-compat guard: a single-screen desk (and every window on the
        // primary of a multi-screen desk) must normalize exactly as before.
        let window = DisplayRect(x: 200, y: 100, width: 1200, height: 800)
        let frame = DisplayGeometry.normalize(window: window, on: primary)
        XCTAssertEqual(frame.x, 200.0 / 3440.0, accuracy: 0.0001)
        XCTAssertEqual(frame.y, 100.0 / 1440.0, accuracy: 0.0001)
        assertOnCanvas(frame, "a primary-display window was always on-canvas and must stay so")
    }

    func testDegenerateDisplayYieldsZeroFrameNotNaN() {
        // A display mid-reconfiguration (or just disconnected) reports a zero
        // frame. Dividing by it would put NaN on the wire and the phone would
        // draw nothing at all, with no clue why.
        let frame = DisplayGeometry.normalize(
            window: DisplayRect(x: 10, y: 10, width: 100, height: 100),
            on: DisplayRect(x: 0, y: 0, width: 0, height: 0))
        XCTAssertEqual(frame, WindowFrame(x: 0, y: 0, width: 0, height: 0))
    }

    // MARK: - Desktop span

    func testSpanCoversBothDisplays() {
        let span = DisplayGeometry.span(of: [primary, secondary])
        XCTAssertEqual(span.x, 0)
        XCTAssertEqual(span.width, 6000, "3440 + 2560")
        XCTAssertEqual(span.height, 1440)
    }

    func testSpanHandlesADisplayLeftOfPrimary() {
        // Monitors to the LEFT of the primary have negative CG x. The span has
        // to start there, or every window on that screen composes negative.
        let left = DisplayRect(x: -2560, y: 0, width: 2560, height: 1440)
        let span = DisplayGeometry.span(of: [primary, left])
        XCTAssertEqual(span.x, -2560)
        XCTAssertEqual(span.width, 6000)

        let frame = DisplayGeometry.spanFrame(of: left, in: span)
        XCTAssertEqual(frame.x, 0, accuracy: 0.0001, "the leftmost display starts the span")
        XCTAssertEqual(frame.width, 2560.0 / 6000.0, accuracy: 0.0001)
    }

    func testSingleDisplaySpanIsTheUnitRect() {
        // The merged "All screens" canvas must be identical to the single-screen
        // canvas on a one-monitor Mac, or this whole feature would move windows
        // for users who have nothing to switch between.
        let span = DisplayGeometry.span(of: [primary])
        XCTAssertEqual(DisplayGeometry.spanFrame(of: primary, in: span),
                       WindowFrame(x: 0, y: 0, width: 1, height: 1))
    }

    func testEmptyDisplayListDoesNotDivideByZero() {
        let span = DisplayGeometry.span(of: [])
        XCTAssertEqual(span.width, 1)
        XCTAssertEqual(span.height, 1)
    }

    // MARK: - Merged canvas composition (the phone's "All" chip)

    func testComposingBackOntoTheSpanReproducesTheTrueGlobalPosition() {
        // The Mac splits (window ÷ its display), the phone composes
        // (display's span slot + window inside it). The round trip must land
        // exactly where the window really is on the desktop, or the "All" view
        // lies about which monitor things are on.
        let terminal = DisplayRect(x: 3600, y: 200, width: 1200, height: 800)
        let span = DisplayGeometry.span(of: [primary, secondary])

        let perDisplay = DisplayGeometry.normalize(window: terminal, on: secondary)
        let slot = DisplayGeometry.spanFrame(of: secondary, in: span)
        let composed = DisplayGeometry.spanFrame(ofWindow: perDisplay, onDisplay: slot)

        let direct = DisplayGeometry.normalize(window: terminal, on: span)
        XCTAssertEqual(composed.x, direct.x, accuracy: 0.0001)
        XCTAssertEqual(composed.y, direct.y, accuracy: 0.0001)
        XCTAssertEqual(composed.width, direct.width, accuracy: 0.0001)
        XCTAssertEqual(composed.height, direct.height, accuracy: 0.0001)
        assertOnCanvas(composed, "the merged canvas must contain every window")
    }

    func testComposingOnASingleDisplayIsIdentity() {
        let frame = WindowFrame(x: 0.25, y: 0.5, width: 0.3, height: 0.2)
        let unit = WindowFrame(x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(DisplayGeometry.spanFrame(ofWindow: frame, onDisplay: unit), frame)
    }

    // MARK: - Which display a window is on

    func testWindowIsAssignedToTheDisplayContainingItsCenter() {
        let onSecond = DisplayRect(x: 3600, y: 200, width: 1200, height: 800)
        XCTAssertEqual(DisplayGeometry.displayID(forWindow: onSecond, displays: displays), "d-second")

        let onPrimary = DisplayRect(x: 200, y: 100, width: 1200, height: 800)
        XCTAssertEqual(DisplayGeometry.displayID(forWindow: onPrimary, displays: displays), "d-primary")
    }

    func testWindowStraddlingTheSeamGoesWhereItsCenterIs() {
        // Dragged across the boundary, mostly on the primary: center at
        // x = 3200 + 600 = 3800... which is on the SECOND screen. The center
        // rule is the same one the Mac's own display filter uses, so both
        // agree about where a straddling window lives.
        let straddling = DisplayRect(x: 3200, y: 100, width: 1200, height: 800)
        XCTAssertEqual(DisplayGeometry.displayID(forWindow: straddling, displays: displays), "d-second")
    }

    func testWindowInAGapFallsBackToPrimaryRatherThanVanishing() {
        // Mismatched monitor heights leave dead zones no display contains. A
        // window there must still get a display id — otherwise it is filtered
        // out of every screen chip and the user cannot reach it at all.
        let tall = DisplayRect(x: 0, y: 0, width: 3440, height: 1440)
        let short = DisplayRect(x: 3440, y: 0, width: 2560, height: 720)
        let list: [(id: String, isPrimary: Bool, rect: DisplayRect)] =
            [(id: "d-primary", isPrimary: true, rect: tall),
             (id: "d-short", isPrimary: false, rect: short)]
        // Below the short monitor, to the right of the tall one: in no display.
        let orphan = DisplayRect(x: 4000, y: 1000, width: 400, height: 300)
        XCTAssertEqual(DisplayGeometry.displayID(forWindow: orphan, displays: list), "d-primary")
    }

    func testNoDisplaysMeansNoDisplayID() {
        let window = DisplayRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(DisplayGeometry.displayID(forWindow: window, displays: []))
    }

    // MARK: - Wire compatibility

    func testLayoutUpdateWithoutDisplaysStillDecodes() throws {
        // An older Mac build sends no `displays` / `spanAspect`. The phone must
        // treat that as "one screen", not fail to decode the layout and show
        // an empty grid.
        let json = """
        {"type":"layout_update","monitor":"C34J79x","screenAspect":2.388,"windows":[]}
        """
        let update = try JSONDecoder().decode(LayoutUpdate.self, from: Data(json.utf8))
        XCTAssertNil(update.displays)
        XCTAssertNil(update.spanAspect)
        XCTAssertEqual(update.monitor, "C34J79x")
    }

    func testWindowStateWithoutDisplayIDStillDecodes() throws {
        let json = """
        {"id":"w1","name":"n","app":"iTerm2","enabled":true,
         "frame":{"x":0,"y":0,"width":0.5,"height":0.5},
         "state":"neutral","color":"#FFFFFF"}
        """
        let state = try JSONDecoder().decode(WindowState.self, from: Data(json.utf8))
        XCTAssertNil(state.displayID, "nil means 'the primary display' to the client")
        XCTAssertNil(state.spaceID, "nil means an older Mac did not report Space metadata")
    }

    func testLayoutUpdateWithoutSpacesStillDecodes() throws {
        let json = #"{"type":"layout_update","monitor":"Mac","windows":[]}"#
        let update = try JSONDecoder().decode(LayoutUpdate.self, from: Data(json.utf8))
        XCTAssertNil(update.spaces)
    }

    func testSpaceMetadataRoundTrips() throws {
        let window = WindowState(id: "w", name: "Terminal", app: "iTerm2",
                                 enabled: true,
                                 frame: WindowFrame(x: 0, y: 0, width: 1, height: 1),
                                 state: "neutral", color: "#fff",
                                 spaceID: "space-4")
        let original = LayoutUpdate(monitor: "Mac", windows: [window],
                                    spaces: [SpaceState(id: "space-4", name: "Desktop 4", isCurrent: true)])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LayoutUpdate.self, from: data)
        XCTAssertEqual(decoded.windows.first?.spaceID, "space-4")
        XCTAssertEqual(decoded.spaces?.first?.isCurrent, true)
    }

    func testLayoutUpdateRoundTripsDisplays() throws {
        let displays = [
            DisplayState(id: "display-1", name: "C34J79x", isPrimary: true, aspect: 3440.0 / 1440.0,
                         spanFrame: WindowFrame(x: 0, y: 0, width: 3440.0 / 6000.0, height: 1)),
            DisplayState(id: "display-2", name: "Studio Display", isPrimary: false, aspect: 2560.0 / 1440.0,
                         spanFrame: WindowFrame(x: 3440.0 / 6000.0, y: 0, width: 2560.0 / 6000.0, height: 1)),
        ]
        let update = LayoutUpdate(monitor: "C34J79x", screenAspect: 3440.0 / 1440.0, windows: [],
                                  displays: displays, spanAspect: 6000.0 / 1440.0)
        let decoded = try JSONDecoder().decode(LayoutUpdate.self,
                                               from: try JSONEncoder().encode(update))
        XCTAssertEqual(decoded.displays, displays)
        XCTAssertEqual(decoded.spanAspect, 6000.0 / 1440.0)
        XCTAssertEqual(decoded.displays?.first(where: { $0.isPrimary })?.name, "C34J79x")
    }
}
