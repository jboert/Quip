import XCTest
@testable import Quip

/// Q-51 US-212: the hold menu and VoiceOver's Actions come from one list, so
/// these pin what each kind of slot offers and in which order.
final class QuickMenuTests: XCTestCase {
    private func titles(_ facts: QuickMenu.Facts) -> [String] {
        QuickMenu.items(facts).map(\.title)
    }

    func test_aPlainKeyOffersColorSpacerAndRemove() {
        XCTAssertEqual(titles(.init(canSendTo: true, canEdit: true)),
                       ["Send to…", "Edit…", "Color…", "Add Spacer After", "Remove from Row"])
    }

    func test_aSlashKeyLeadsWithTheSlashPalette() {
        XCTAssertEqual(titles(.init(isSlash: true, canSendTo: true, canEdit: true)),
                       ["All Slash Commands…", "Send to…", "Edit…", "Color…", "Add Spacer After", "Remove from Row"])
    }

    func test_aPromptLeadsWithPasteAndSend() {
        XCTAssertEqual(titles(.init(isPrompt: true, canSendTo: true, canEdit: true)),
                       ["Paste & Send", "Send to…", "Edit…", "Color…", "Add Spacer After", "Remove from Row"])
    }

    func test_colorIsInEditWhenTheEditFormCarriesIt() {
        XCTAssertEqual(titles(.init(isSlash: true, canSendTo: true, canEdit: true, editIncludesColor: true)),
                       ["All Slash Commands…", "Send to…", "Edit…", "Add Spacer After", "Remove from Row"])
        // A prompt's Edit… edits the library prompt, so its pill keeps Color….
        XCTAssertTrue(titles(.init(isPrompt: true, canSendTo: true, canEdit: true)).contains("Color…"))
    }

    func test_aSpacerHasNothingToColorOrEdit() {
        XCTAssertEqual(titles(.init(isSpacer: true)), ["Add Spacer After", "Remove from Row"])
    }

    func test_onlyRemoveIsDestructive() {
        XCTAssertEqual(QuickMenuItem.allCases.filter(\.isDestructive), [.remove])
    }

    func test_everyItemHasADistinctTitle() {
        let all = QuickMenuItem.allCases.map(\.title)
        XCTAssertEqual(Set(all).count, all.count, "VoiceOver lists actions by name; two alike would be ambiguous")
    }
}
