import XCTest
import UIKit
@testable import Quip

/// Pins the InlineTerminalContent render-branch decision.
///
/// Why this test exists: commit 440b175 shipped the `LinkableTerminalText`
/// UITextView path assuming it was the live render path. It wasn't — the Mac
/// always sends a screenshot alongside the text content, iOS's branch
/// conditional checks `screenshot` first, and the UITextView path only runs
/// when screenshot capture fails. Covered the linkifier, missed the branch.
///
/// These tests pin the mapping so future changes to the priority rule
/// (e.g. "prefer text for terminal windows") break a test instead of silently
/// regressing the user experience.
final class InlineTerminalContentBranchTests: XCTestCase {

    private func pngBase64(size: CGSize = CGSize(width: 8, height: 8)) -> String {
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return img.pngData()!.base64EncodedString()
    }

    func test_screenshot_present_and_decodes_takes_image_branch() {
        // Image-first: Claude Code's TUI lives in the alternate screen buffer
        // which the Mac's text scrape doesn't capture. The screenshot is the
        // only way to show the input box users actually interact with.
        // URL linkification lives behind this — tracked as a wishlist item.
        let png = pngBase64()
        let b = InlineTerminalContent.branch(content: "some terminal text", screenshot: png)
        XCTAssertEqual(b, .image, "screenshot wins over text — Claude TUI is in alt-screen which text scrape misses")
    }

    func test_screenshot_nil_with_text_falls_back_to_text() {
        // Priority is image > text > loading. User's explicit preference is
        // that plain text beats an empty Loading screen — so when no
        // screenshot is available but content exists, we render the text
        // branch. The state layer's last-good-screenshot preservation keeps
        // this case rare: once any screenshot has been received for the
        // current window, a subsequent nil-screenshot update doesn't clear
        // the cached image, so .image stays live.
        let b = InlineTerminalContent.branch(content: "some terminal text", screenshot: nil)
        XCTAssertEqual(b, .text)
    }

    func test_screenshot_non_decodable_falls_back_to_text() {
        let b = InlineTerminalContent.branch(content: "hi", screenshot: "not-base64-at-all!!!")
        XCTAssertEqual(b, .text, "garbage screenshot payload must not strand the view in image branch; text beats Loading…")
    }

    func test_empty_content_no_screenshot_is_loading() {
        let b = InlineTerminalContent.branch(content: "", screenshot: nil)
        XCTAssertEqual(b, .loading)
    }

    func test_empty_content_with_screenshot_still_shows_image() {
        let png = pngBase64()
        let b = InlineTerminalContent.branch(content: "", screenshot: png)
        XCTAssertEqual(b, .image, "screenshot-only windows (non-terminal apps) must render the image")
    }

    func test_base64_that_is_not_an_image_falls_back_to_text() {
        // "hello" base64-encoded — valid base64, invalid PNG/JPEG.
        let b = InlineTerminalContent.branch(content: "body", screenshot: "aGVsbG8=")
        XCTAssertEqual(b, .text, "base64 that doesn't decode to UIImage falls back to text, not Loading…")
    }

    // Pins the zoomScale mapping (issue #7). The image branch reads this to
    // size the screenshot relative to the viewport — if the 1.0/1.5/2.5
    // ladder changes, widescreen-terminal users either lose vertical scroll
    // room again (< 1.0 somewhere) or get yanked off-screen (very large),
    // so both directions matter.
    func test_zoom_scale_mapping_fit_is_one() {
        XCTAssertEqual(ContentZoomLevel.fit.zoomScale, 1.0, accuracy: 0.001)
    }

    func test_zoom_scale_mapping_medium_is_above_one() {
        XCTAssertGreaterThan(ContentZoomLevel.medium.zoomScale, 1.0,
                             "medium zoom must exceed 1.0 or there's no extra scroll range over .fit")
    }

    func test_zoom_scale_mapping_large_is_greater_than_medium() {
        XCTAssertGreaterThan(ContentZoomLevel.large.zoomScale, ContentZoomLevel.medium.zoomScale,
                             "cases are monotonic — cycling fit → medium → large must scale up each step")
    }

    func test_zoom_level_from_unknown_raw_defaults_to_fit() {
        // Guard against a corrupt @AppStorage / PreferencesSnapshot value —
        // anything outside 0…2 must fall back to the no-overflow default so
        // the screenshot doesn't scroll off-screen on first render.
        XCTAssertEqual(ContentZoomLevel.from(raw: 99), .fit)
        XCTAssertEqual(ContentZoomLevel.from(raw: -1), .fit)
    }

    func test_zoom_level_next_cycles_through_all_cases() {
        // Header cycler button depends on this — the tap handler stores
        // .next as the new rawValue so the sequence must wrap back to fit.
        let fitNext    = ContentZoomLevel.fit.next
        let mediumNext = ContentZoomLevel.medium.next
        let largeNext  = ContentZoomLevel.large.next
        XCTAssertEqual(fitNext, ContentZoomLevel.medium.rawValue)
        XCTAssertEqual(mediumNext, ContentZoomLevel.large.rawValue)
        XCTAssertEqual(largeNext, ContentZoomLevel.fit.rawValue)
    }
}
