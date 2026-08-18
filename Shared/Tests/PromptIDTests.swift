import XCTest
@testable import Quip

/// `PromptID.sanitize` is a two-peer contract: the Mac uses it to derive the
/// on-disk filename, and the iOS editor uses it to preview that filename before
/// the user saves. If they ever disagree, the phone shows one id and the Mac
/// writes another. These tests pin the shape both peers depend on.
final class PromptIDTests: XCTestCase {

    func testKeepsAllowedCharacters() {
        XCTAssertEqual(PromptID.sanitize("ship-it_2.0"), "ship-it_2.0")
    }

    func testSpacesBecomeDashes() {
        XCTAssertEqual(PromptID.sanitize("ship it now"), "ship-it-now")
    }

    func testDropsShellAndPathMetacharacters() {
        XCTAssertEqual(PromptID.sanitize("ship/it;rm -rf"), "shipitrm--rf")
        XCTAssertEqual(PromptID.sanitize("../../etc/passwd"), "etcpasswd")
    }

    func testStripsLeadingDots() {
        XCTAssertEqual(PromptID.sanitize("...hidden"), "hidden")
        XCTAssertEqual(PromptID.sanitize(".."), "")
    }

    func testEmptyResultIsRejectable() {
        XCTAssertEqual(PromptID.sanitize("!!!"), "")
        XCTAssertEqual(PromptID.sanitize(""), "")
    }

    func testPreservesCaseAndUnicodeLetters() {
        XCTAssertEqual(PromptID.sanitize("ShipIt"), "ShipIt")
        XCTAssertEqual(PromptID.sanitize("café"), "café")
    }

    /// The Mac's own entry point must route through the shared implementation,
    /// otherwise the contract is only nominally shared. Mac-only: this file also
    /// compiles into the iOS test target, where `PromptLibrary` does not exist.
    #if os(macOS)
    @MainActor
    func testPromptLibraryDelegatesToSharedSanitizer() {
        for raw in ["ship it", "../escape", ".dotfile", "keep_me-1.2", "!!!"] {
            XCTAssertEqual(PromptLibrary.sanitizeID(raw), PromptID.sanitize(raw),
                           "PromptLibrary.sanitizeID diverged from PromptID.sanitize for \(raw)")
        }
    }
    #endif

    func testWouldCollideDetectsExistingID() {
        let existing: Set<String> = ["ship-it", "deploy"]
        XCTAssertTrue(PromptID.collides("ship it", with: existing))
        XCTAssertFalse(PromptID.collides("ship it 2", with: existing))
        XCTAssertFalse(PromptID.collides("!!!", with: existing))
    }
}
