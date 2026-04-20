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

    func test_screenshot_nil_with_text_takes_text_branch() {
        let b = InlineTerminalContent.branch(content: "some terminal text", screenshot: nil)
        XCTAssertEqual(b, .text)
    }

    func test_screenshot_non_decodable_falls_through_to_text() {
        let b = InlineTerminalContent.branch(content: "hi", screenshot: "not-base64-at-all!!!")
        XCTAssertEqual(b, .text, "garbage screenshot payload must not strand the view in image branch")
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

    func test_base64_that_is_not_an_image_falls_through() {
        // "hello" base64-encoded — valid base64, invalid PNG/JPEG.
        let b = InlineTerminalContent.branch(content: "body", screenshot: "aGVsbG8=")
        XCTAssertEqual(b, .text, "base64 that doesn't decode to UIImage must not trap the view in image branch")
    }
}
