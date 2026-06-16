import XCTest
import AppKit
@testable import Quip

/// Regression coverage for the clipboard-injection coordinator.
///
/// Bug: pasteText/pasteImage/sendText[Claude] stomp NSPasteboard.general to
/// inject content, then restore the user's clipboard after a delay. When two
/// injections overlap (rapid grok/codex voice sends land ~0.5s apart, inside
/// the 0.6s restore window), the second call used to snapshot the FIRST call's
/// injected text as if it were the user's clipboard, and the staggered restores
/// clobbered each other — leaving injected prompt text on the user's clipboard.
///
/// The coordinator snapshots the real original ONCE per burst (0→1) and restores
/// it exactly once, when the last outstanding injection finishes.
final class KeystrokeInjectorClipboardTests: XCTestCase {
    private var savedClipboard: String?

    override func setUp() {
        super.setUp()
        // Preserve the developer's real clipboard across the test.
        savedClipboard = NSPasteboard.general.string(forType: .string)
    }

    override func tearDown() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let s = savedClipboard { pb.setString(s, forType: .string) }
        super.tearDown()
    }

    /// Pump the main run loop briefly so the asyncAfter restore blocks fire.
    private func drainMainQueue() {
        let drained = expectation(description: "restores drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)
    }

    @MainActor
    func test_overlapping_pastes_restore_user_original_not_injected_text() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("USER_ORIGINAL", forType: .string)

        // Paste A begins the burst — snapshots the user's real clipboard.
        let originalA = KeystrokeInjector.beginClipboardInjection()
        XCTAssertEqual(originalA, "USER_ORIGINAL")
        pb.clearContents(); pb.setString("INJECT_A", forType: .string)

        // Paste B overlaps (A's restore hasn't fired). It must NOT re-snapshot
        // the now-injected "INJECT_A" — this is the exact bug being fixed.
        let originalB = KeystrokeInjector.beginClipboardInjection()
        XCTAssertEqual(originalB, "USER_ORIGINAL",
                       "overlapping paste re-snapshotted injected text instead of the user's clipboard")
        pb.clearContents(); pb.setString("INJECT_B", forType: .string)

        // Both injections finish. Only the last restores, to the real original.
        KeystrokeInjector.endClipboardInjection(after: 0)
        KeystrokeInjector.endClipboardInjection(after: 0)
        drainMainQueue()

        XCTAssertEqual(pb.string(forType: .string), "USER_ORIGINAL",
                       "burst left injected text on the clipboard instead of the user's original")
    }

    @MainActor
    func test_single_paste_restores_original() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("ONLY_ORIGINAL", forType: .string)

        KeystrokeInjector.beginClipboardInjection()
        pb.clearContents(); pb.setString("INJECTED", forType: .string)
        KeystrokeInjector.endClipboardInjection(after: 0)
        drainMainQueue()

        XCTAssertEqual(pb.string(forType: .string), "ONLY_ORIGINAL")
    }

    /// A second burst that starts AFTER the first fully drains must snapshot the
    /// restored original, not stale state from the previous burst.
    @MainActor
    func test_sequential_bursts_each_restore_their_own_original() {
        let pb = NSPasteboard.general

        pb.clearContents(); pb.setString("FIRST", forType: .string)
        KeystrokeInjector.beginClipboardInjection()
        pb.clearContents(); pb.setString("INJECT_1", forType: .string)
        KeystrokeInjector.endClipboardInjection(after: 0)
        drainMainQueue()
        XCTAssertEqual(pb.string(forType: .string), "FIRST")

        pb.clearContents(); pb.setString("SECOND", forType: .string)
        let original2 = KeystrokeInjector.beginClipboardInjection()
        XCTAssertEqual(original2, "SECOND", "new burst snapshotted stale clipboard")
        pb.clearContents(); pb.setString("INJECT_2", forType: .string)
        KeystrokeInjector.endClipboardInjection(after: 0)
        drainMainQueue()
        XCTAssertEqual(pb.string(forType: .string), "SECOND")
    }
}
