import XCTest
@testable import Quip

final class ClaudePreviewLogicTests: XCTestCase {
    private func item(_ id: String, terminal: String?) -> ClaudePreviewItem {
        ClaudePreviewItem(id: id, name: "\(id).png", terminalWindowId: terminal, openedAt: 0,
                          hasDesktopWindow: true, thumb: nil, isPDF: false)
    }

    func test_terminalShowsItsOwnAndUnattachedPreviews() {
        let items = [item("a", terminal: "t1"), item("b", terminal: "t2"), item("c", terminal: nil)]
        let shown = ClaudePreviewLogic.visible(items, selectedWindowId: "t1", knownWindowIds: ["t1", "t2"])
        XCTAssertEqual(shown.map(\.id), ["a", "c"])
    }

    func test_previewOfAClosedTerminalStillShows() {
        let items = [item("a", terminal: "gone")]
        XCTAssertEqual(ClaudePreviewLogic.visible(items, selectedWindowId: "t1", knownWindowIds: ["t1"]).map(\.id), ["a"])
    }

    func test_fitScaleFitsTheWholeImage() {
        // 1290×2796 simulator shot in a 390×700 viewport: height-bound.
        let fit = ZoomMath.fitScale(image: CGSize(width: 1290, height: 2796), viewport: CGSize(width: 390, height: 700))
        XCTAssertEqual(fit, 700 / 2796, accuracy: 0.0001)
    }

    func test_pixelScaleIsOneImagePixelPerScreenPixel() {
        XCTAssertEqual(ZoomMath.pixelScale(screenScale: 3), 1.0 / 3, accuracy: 0.0001)
    }

    func test_maxZoomReachesPast100Percent() {
        XCTAssertGreaterThanOrEqual(ZoomMath.maxScale(fit: 0.25, pixel: 1.0 / 3), 4.0 / 3)
    }

    func test_doubleTapGoesFitTo100AndBack() {
        let fit: CGFloat = 0.25, pixel: CGFloat = 1.0 / 3
        XCTAssertEqual(ZoomMath.doubleTapTarget(current: fit, fit: fit, pixel: pixel), pixel)
        XCTAssertEqual(ZoomMath.doubleTapTarget(current: 1.0, fit: fit, pixel: pixel), fit)
    }

    func test_doubleTapOnSmallImageStillZoomsIn() {
        // 100%≈fit (or below): go to 2.5× fit so the tap does something.
        XCTAssertEqual(ZoomMath.doubleTapTarget(current: 2, fit: 2, pixel: 1.0 / 3), 5)
    }

    func test_zoomRectCentresOnTapAndStaysInsideImage() {
        let image = CGSize(width: 1000, height: 2000), viewport = CGSize(width: 400, height: 800)
        let r = ZoomMath.zoomRect(around: CGPoint(x: 500, y: 1000), scale: 1, viewport: viewport, image: image)
        XCTAssertEqual(r, CGRect(x: 300, y: 600, width: 400, height: 800))
        let corner = ZoomMath.zoomRect(around: CGPoint(x: 0, y: 0), scale: 1, viewport: viewport, image: image)
        XCTAssertEqual(corner.origin, .zero)
        let far = ZoomMath.zoomRect(around: CGPoint(x: 1000, y: 2000), scale: 1, viewport: viewport, image: image)
        XCTAssertEqual(far.maxX, 1000)
        XCTAssertEqual(far.maxY, 2000)
    }

    func test_centeringInsetsOnlyWhenSmaller() {
        let i = ZoomMath.centeringInsets(content: CGSize(width: 200, height: 1000), viewport: CGSize(width: 400, height: 800))
        XCTAssertEqual(i.horizontal, 100)
        XCTAssertEqual(i.vertical, 0)
    }
}
