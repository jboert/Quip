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
}
