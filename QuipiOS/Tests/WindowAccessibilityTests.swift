import XCTest
@testable import Quip

final class WindowAccessibilityTests: XCTestCase {
    func test_windowLabelUsesFolderWhenAvailable() {
        let window = makeWindow(id: "win-1",
                                name: "Codex",
                                app: "iTerm2",
                                folder: "nugget-expo")

        XCTAssertEqual(WindowAccessibility.windowLabel(for: window),
                       "Window: iTerm2 - nugget-expo")
        XCTAssertEqual(WindowAccessibility.tileIdentifier(for: window),
                       "window-tile-win-1")
    }

    func test_windowLabelFallsBackToWindowName() {
        let window = makeWindow(id: "win-2",
                                name: "Claude Code",
                                app: "Terminal",
                                folder: nil)

        XCTAssertEqual(WindowAccessibility.windowLabel(for: window),
                       "Window: Terminal - Claude Code")
    }

    func test_qaPaneLabelAndIdentifierAreStable() {
        let window = makeWindow(id: "qa-terminal",
                                name: "Codex",
                                app: "iTerm2",
                                folder: "Quip")

        XCTAssertEqual(WindowAccessibility.qaPaneLabel(for: window),
                       "QA pane: iTerm2 - Quip")
        XCTAssertEqual(WindowAccessibility.qaPaneIdentifier(for: window),
                       "qa-pane-qa-terminal")
    }

    func test_accessibilityValueDistinguishesSelectionAndEnabledState() {
        XCTAssertEqual(WindowAccessibility.value(isSelected: true, isEnabled: true), "Selected")
        XCTAssertEqual(WindowAccessibility.value(isSelected: true, isEnabled: false), "Selected, disabled")
        XCTAssertEqual(WindowAccessibility.value(isSelected: false, isEnabled: true), "Available")
        XCTAssertEqual(WindowAccessibility.value(isSelected: false, isEnabled: false), "Disabled")
    }

    private func makeWindow(id: String,
                            name: String,
                            app: String,
                            folder: String?) -> WindowState {
        WindowState(id: id,
                    name: name,
                    app: app,
                    folder: folder,
                    enabled: true,
                    frame: WindowFrame(x: 0, y: 0, width: 0.5, height: 0.5),
                    state: "idle",
                    color: "#4A90E2")
    }
}
