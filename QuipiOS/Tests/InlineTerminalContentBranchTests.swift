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

    // MARK: - Explicit mode override (Settings → Appearance → Content mode)

    func test_image_mode_with_screenshot_renders_image() {
        let png = pngBase64()
        let b = InlineTerminalContent.branch(content: "text here", screenshot: png, mode: .image)
        XCTAssertEqual(b, .image)
    }

    func test_image_mode_without_screenshot_stays_loading_not_text() {
        // The whole point of the override: never silently flip to text when
        // the user has explicitly asked for image mode. Loading instead so
        // they see the panel waiting rather than auto-falling back.
        let b = InlineTerminalContent.branch(content: "text here", screenshot: nil, mode: .image)
        XCTAssertEqual(b, .loading)
    }

    func test_image_mode_with_undecodable_screenshot_stays_loading() {
        let b = InlineTerminalContent.branch(content: "text", screenshot: "not-base64-at-all!!!", mode: .image)
        XCTAssertEqual(b, .loading)
    }

    func test_text_mode_with_content_renders_text_even_when_screenshot_present() {
        // Inverse override: user wants text, screenshot is irrelevant.
        let png = pngBase64()
        let b = InlineTerminalContent.branch(content: "terminal output", screenshot: png, mode: .text)
        XCTAssertEqual(b, .text)
    }

    func test_text_mode_without_content_is_loading() {
        let b = InlineTerminalContent.branch(content: "", screenshot: nil, mode: .text)
        XCTAssertEqual(b, .loading)
    }

    func test_auto_mode_matches_legacy_behavior() {
        // Sanity: passing .auto explicitly == calling without the parameter.
        let png = pngBase64()
        XCTAssertEqual(
            InlineTerminalContent.branch(content: "x", screenshot: png, mode: .auto),
            InlineTerminalContent.branch(content: "x", screenshot: png)
        )
        XCTAssertEqual(
            InlineTerminalContent.branch(content: "", screenshot: nil, mode: .auto),
            InlineTerminalContent.branch(content: "", screenshot: nil)
        )
    }
}
