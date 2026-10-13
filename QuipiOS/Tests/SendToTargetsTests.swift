import XCTest
@testable import Quip

/// "Send to…" from a keyboard button's hold menu (Q-51).
final class SendToTargetsTests: XCTestCase {
    private func window(_ id: String, app: String = "iTerm2", name: String = "zsh",
                        folder: String? = nil) -> WindowState {
        WindowState(id: id, name: name, app: app, folder: folder, enabled: true,
                    frame: WindowFrame(x: 0, y: 0, width: 1, height: 1),
                    state: "neutral", color: "#4A90E2")
    }

    func test_onlyTerminalsCurrentFirstThenByFolder() {
        let targets = SendToTargets.targets(from: [
            window("w", folder: "web"),
            window("s", app: "Safari", name: "Docs"),
            window("a", folder: "api"),
            window("c", app: "Terminal", folder: "cli"),
        ], selectedID: "w")
        XCTAssertEqual(targets.map(\.id), ["w", "a", "c"])
        XCTAssertEqual(targets.map(\.isCurrent), [true, false, false])
        XCTAssertEqual(targets[1].detail, "iTerm2 · zsh")
    }

    func test_noFolderUsesTheWindowNameAndAppAlone() {
        let t = SendToTargets.targets(from: [window("x", name: "build", folder: "")], selectedID: nil)
        XCTAssertEqual(t.first?.title, "build")
        XCTAssertEqual(t.first?.detail, "iTerm2")
        XCTAssertEqual(t.first?.isCurrent, false)
    }

    func test_whatEachSlotSends() {
        let id = UUID()
        let text = CustomButton(id: id, label: "hi", systemImage: nil, payload: .rawText(text: "hi", autoSubmit: false))
        XCTAssertEqual(QuickSend.action(for: .builtin(.compact), defs: []), .text("/compact", pressReturn: true))
        XCTAssertEqual(QuickSend.action(for: .builtin(.esc), defs: []), .keystroke("press_escape"))
        XCTAssertEqual(QuickSend.action(for: .custom(id), defs: [text]), .text("hi", pressReturn: false))
        XCTAssertEqual(QuickSend.action(for: .prompt(promptID: "ship"), defs: []), .prompt(id: "ship", pressReturn: false))
        XCTAssertNil(QuickSend.action(for: .builtin(.broadcast), defs: []))
        XCTAssertNil(QuickSend.action(for: .promptsPicker, defs: []))
        XCTAssertNil(QuickSend.action(for: .spacer(UUID()), defs: []))
        XCTAssertNil(QuickSend.action(for: .custom(UUID()), defs: [text]))
    }

    func test_returnChoiceOnlyForTypedTextAndPrompts() {
        XCTAssertEqual(QuickSend.text("hi", pressReturn: false).pressingReturn(true), .text("hi", pressReturn: true))
        XCTAssertEqual(QuickSend.prompt(id: "p", pressReturn: false).pressingReturn(true), .prompt(id: "p", pressReturn: true))
        // Already submits, or a key: unchanged whatever the toggle says.
        XCTAssertEqual(QuickSend.text("/compact", pressReturn: true).pressingReturn(false), .text("/compact", pressReturn: true))
        XCTAssertEqual(QuickSend.keystroke("press_y").pressingReturn(true), .keystroke("press_y"))
        XCTAssertFalse(QuickSend.keystroke("press_y").offersReturnChoice)
    }
}
