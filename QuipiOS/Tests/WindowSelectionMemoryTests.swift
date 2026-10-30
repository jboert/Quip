import XCTest
@testable import Quip

final class WindowSelectionMemoryTests: XCTestCase {
    func test_reconnectRestoresTheRememberedWindow() {
        XCTAssertEqual(
            WindowSelectionMemory.initialSelection(remembered: "iterm-42", available: ["iterm-7", "iterm-42"]),
            "iterm-42")
    }

    func test_rememberedWindowGone_fallsBackToFirst() {
        XCTAssertEqual(
            WindowSelectionMemory.initialSelection(remembered: "iterm-42", available: ["iterm-7", "iterm-9"]),
            "iterm-7")
    }

    func test_nothingRemembered_picksFirst() {
        XCTAssertEqual(
            WindowSelectionMemory.initialSelection(remembered: nil, available: ["iterm-7", "iterm-9"]),
            "iterm-7")
    }

    func test_noWindows_selectsNothing() {
        XCTAssertNil(WindowSelectionMemory.initialSelection(remembered: "iterm-42", available: []))
    }

    func test_keyIsNamespacedPerBackend() {
        XCTAssertNotEqual(WindowSelectionMemory.key(forBackendId: "mac-a"),
                          WindowSelectionMemory.key(forBackendId: "mac-b"))
    }

    // MARK: Recent windows (Q-88)

    private func touched(_ ids: [String]) -> [String] {
        ids.reduce([]) { WindowSelectionMemory.touched($0, with: $1) }
    }

    /// A throwaway suite, so these tests never touch UserDefaults.standard.
    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "WindowSelectionMemoryTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func test_touch_putsTheLatestFirst() {
        XCTAssertEqual(touched(["A", "B", "C"]), ["C", "B", "A"])
    }

    func test_touchAgain_movesToTopWithoutDuplicating() {
        XCTAssertEqual(touched(["A", "B", "C", "B"]), ["B", "C", "A"])
    }

    func test_cap_keepsTwentyAndDropsTheOldest() {
        let recent = touched((1...21).map { "w\($0)" })
        XCTAssertEqual(recent.count, 20)
        XCTAssertEqual(recent.first, "w21")
        XCTAssertFalse(recent.contains("w1"))
    }

    func test_prune_keepsOnlyAvailable() {
        XCTAssertEqual(WindowSelectionMemory.pruned(["C", "B", "A"], keeping: ["A"]), ["A"])
    }

    func test_best_skipsTheExcludedWindow() {
        XCTAssertEqual(WindowSelectionMemory.best(recent: ["B", "A"], available: ["A", "B"], excluding: "B"), "A")
    }

    func test_best_nothingAvailable_isNil() {
        XCTAssertNil(WindowSelectionMemory.best(recent: ["B", "A"], available: []))
        XCTAssertNil(WindowSelectionMemory.best(recent: ["B", "A"], available: ["Z"]))
    }

    func test_lastWindowClosed_landsOnThePreviousOne() {
        XCTAssertEqual(
            WindowSelectionMemory.initialSelection(recent: ["C", "B", "A"], available: ["A", "B"]),
            "B")
    }

    func test_recentNothingOpen_picksFirst() {
        XCTAssertEqual(WindowSelectionMemory.initialSelection(recent: ["Z"], available: ["A", "B"]), "A")
        XCTAssertNil(WindowSelectionMemory.initialSelection(recent: ["Z"], available: []))
    }

    func test_remember_keepsTheListPerBackend() {
        let defaults = freshDefaults()
        WindowSelectionMemory.remember("A", forBackendId: "mac-a", defaults: defaults)
        WindowSelectionMemory.remember("B", forBackendId: "mac-a", defaults: defaults)
        WindowSelectionMemory.remember("X", forBackendId: "mac-b", defaults: defaults)
        XCTAssertEqual(WindowSelectionMemory.recent(forBackendId: "mac-a", defaults: defaults), ["B", "A"])
        XCTAssertEqual(WindowSelectionMemory.remembered(forBackendId: "mac-a", defaults: defaults), "B")
        XCTAssertEqual(WindowSelectionMemory.recent(forBackendId: "mac-b", defaults: defaults), ["X"])
    }

    func test_singleIdFromAnEarlierBuild_readsAsAListOfOne() {
        let defaults = freshDefaults()
        defaults.set("iterm-42", forKey: WindowSelectionMemory.key(forBackendId: "mac-a"))
        XCTAssertEqual(WindowSelectionMemory.recent(forBackendId: "mac-a", defaults: defaults), ["iterm-42"])
        XCTAssertEqual(WindowSelectionMemory.remembered(forBackendId: "mac-a", defaults: defaults), "iterm-42")
        WindowSelectionMemory.remember("iterm-7", forBackendId: "mac-a", defaults: defaults)
        XCTAssertEqual(WindowSelectionMemory.recent(forBackendId: "mac-a", defaults: defaults), ["iterm-7", "iterm-42"])
    }

    func test_storedListIsDedupedAndCapped() {
        let defaults = freshDefaults()
        defaults.set(["A", "B", "A"] + (1...25).map { "w\($0)" }, forKey: WindowSelectionMemory.key(forBackendId: "mac-a"))
        let recent = WindowSelectionMemory.recent(forBackendId: "mac-a", defaults: defaults)
        XCTAssertEqual(Array(recent.prefix(2)), ["A", "B"])
        XCTAssertEqual(recent.count, 20)
    }
}
