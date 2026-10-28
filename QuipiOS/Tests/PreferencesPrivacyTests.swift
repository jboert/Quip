import XCTest
@testable import Quip

/// What the iCloud copy of the preferences snapshot may say about prompts that
/// must stay on the owner's devices. Prompt ids here are invented.
@MainActor
final class PreferencesPrivacyTests: XCTestCase {

    private let secret = "vibecut__proj-1a2b3c4d"

    private func usage(_ ids: [String]) -> String {
        var store: PromptRanker.Store = [:]
        let now = Date()
        for id in ids { store = PromptRanker.recording(id, context: "claude", at: now, in: store) }
        return PromptRanker.encode(store)
    }

    func testUsageOfLocalOnlyPromptsIsDropped() {
        var snap = PreferencesSnapshot()
        snap.promptUsageJSON = usage([secret, "vibecut__commit"])
        let out = PreferencesSyncService.scrubbed(snap, localOnly: [secret])
        let store = PromptRanker.decode(out.promptUsageJSON ?? "")
        XCTAssertNil(store[secret])
        XCTAssertNotNil(store["vibecut__commit"])
        XCTAssertFalse((out.promptUsageJSON ?? "").contains(secret))
    }

    func testPinnedSlotAndItsColorForALocalOnlyPromptAreDropped() {
        var snap = PreferencesSnapshot()
        snap.quickSlotsJSON = QuickSlotStore.encode([.promptsPicker, .prompt(promptID: secret), .prompt(promptID: "vibecut__commit")])
        snap.quickSlotColorsJSON = KeyColors.encode(["p:\(secret)": "#FF0000", "p:vibecut__commit": "#00FF00", "pp": "#0000FF"])
        let out = PreferencesSyncService.scrubbed(snap, localOnly: [secret])
        XCTAssertFalse((out.quickSlotsJSON ?? "").contains(secret))
        XCTAssertTrue((out.quickSlotsJSON ?? "").contains("vibecut__commit"))
        XCTAssertEqual(QuickSlotStore.decode(out.quickSlotsJSON ?? "").count, 2)
        XCTAssertFalse((out.quickSlotColorsJSON ?? "").contains(secret))
        XCTAssertEqual(KeyColors.decode(out.quickSlotColorsJSON ?? "").count, 2)
    }

    func testUnknownSlotKindsPassThroughTheScrub() {
        var snap = PreferencesSnapshot()
        snap.quickSlotsJSON = #"[{"kind":"from-the-future","x":1},{"kind":"prompt","promptID":"\#(secret)"}]"#
        let out = PreferencesSyncService.scrubbed(snap, localOnly: [secret])
        XCTAssertTrue((out.quickSlotsJSON ?? "").contains("from-the-future"))
        XCTAssertFalse((out.quickSlotsJSON ?? "").contains(secret))
    }

    func testNothingLocalOnlyLeavesTheSnapshotAlone() {
        var snap = PreferencesSnapshot()
        snap.promptUsageJSON = usage([secret])
        snap.ttsEnabled = true
        XCTAssertEqual(PreferencesSyncService.scrubbed(snap, localOnly: []), snap)
    }

    func testOtherFieldsAreUntouched() {
        var snap = PreferencesSnapshot()
        snap.ttsEnabled = true
        snap.terminalTextSize = 14
        snap.promptUsageJSON = usage([secret])
        let out = PreferencesSyncService.scrubbed(snap, localOnly: [secret])
        XCTAssertEqual(out.ttsEnabled, true)
        XCTAssertEqual(out.terminalTextSize, 14)
    }
}
