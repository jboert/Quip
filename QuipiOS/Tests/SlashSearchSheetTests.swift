import XCTest
@testable import Quip

/// PRD broadcast-and-search US-105: search over the long-press slash palette.
final class SlashSearchSheetTests: XCTestCase {
    private var builtins: [MainiOSView.SlashGroupMember] {
        QuickButton.allCases.filter(\.isSlashCommand).map { .builtin($0) }
    }

    func test_compRanksCompactFirst() {
        XCTAssertEqual(QuickButtonSearch.filter(builtins, query: "comp").first?.id, "b:compact")
    }

    func test_aCustomSlashCommandIsFoundByLabelAndText() {
        let custom = CustomButton(id: UUID(), label: "Review", systemImage: nil,
                                  payload: .slash(text: "/code-review", autoSubmit: true))
        let members = builtins + [.custom(custom)]
        XCTAssertEqual(QuickButtonSearch.filter(members, query: "review").first?.id, "c:\(custom.id.uuidString)")
        XCTAssertEqual(QuickButtonSearch.filter(members, query: "code").first?.id, "c:\(custom.id.uuidString)")
    }

    func test_noQueryKeepsThePaletteOrder() {
        XCTAssertEqual(QuickButtonSearch.filter(builtins, query: "").map(\.id), builtins.map(\.id))
    }

    func test_searchIsOfferedOnlyForMoreThanOneCommand() {
        XCTAssertFalse(SlashSearchSheet.offersSearch(memberCount: 0))
        XCTAssertFalse(SlashSearchSheet.offersSearch(memberCount: 1))
        XCTAssertTrue(SlashSearchSheet.offersSearch(memberCount: 2))
    }

    func test_theRowShowsWhatTheCommandTypes() {
        XCTAssertEqual(MainiOSView.SlashGroupMember.builtin(.commitPushPr).sentText, "/commit-commands:commit-push-pr")
        XCTAssertEqual(MainiOSView.SlashGroupMember.builtin(.plan).sentText, "/plan", "trailing space trimmed")
    }
}
