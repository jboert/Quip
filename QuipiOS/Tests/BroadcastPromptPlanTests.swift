import XCTest
@testable import Quip

final class BroadcastPromptPlanTests: XCTestCase {
    private func window(_ id: String,
                        app: String,
                        targetKind: String? = nil) -> WindowState {
        WindowState(
            id: id,
            name: id,
            app: app,
            enabled: true,
            frame: WindowFrame(x: 0, y: 0, width: 1, height: 1),
            state: "neutral",
            color: "#000000",
            targetKind: targetKind
        )
    }

    func testOnlyTerminalWindowsAreEligibleAndInitiallySelected() {
        let windows = [
            window("iterm", app: "iTerm2"),
            window("terminal", app: "Terminal"),
            window("sim", app: "Simulator", targetKind: "simulator"),
            window("browser", app: "Safari", targetKind: "browser_localhost"),
        ]

        XCTAssertEqual(BroadcastPromptPlan.eligibleWindows(windows).map(\.id), ["iterm", "terminal"])
        XCTAssertEqual(BroadcastPromptPlan.initialSelection(windows: windows), ["iterm", "terminal"])
    }

    func testTargetOrderFollowsTheMacWindowOrder() {
        let windows = [window("b", app: "Terminal"), window("a", app: "iTerm2")]
        let targets = BroadcastPromptPlan.targetIDs(windows: windows, selectedIDs: ["a", "b"])
        XCTAssertEqual(targets, ["b", "a"])
    }

    func testCanSendRequiresConnectionTextAndAtLeastOneTerminal() {
        let windows = [window("terminal", app: "iTerm2")]
        let selected: Set<String> = ["terminal"]

        XCTAssertTrue(BroadcastPromptPlan.canSend(
            text: "  Run the tests.\n",
            windows: windows,
            selectedIDs: selected,
            isConnected: true
        ))
        XCTAssertFalse(BroadcastPromptPlan.canSend(
            text: "  \n",
            windows: windows,
            selectedIDs: selected,
            isConnected: true
        ))
        XCTAssertFalse(BroadcastPromptPlan.canSend(
            text: "Run the tests.",
            windows: windows,
            selectedIDs: [],
            isConnected: true
        ))
        XCTAssertFalse(BroadcastPromptPlan.canSend(
            text: "Run the tests.",
            windows: windows,
            selectedIDs: selected,
            isConnected: false
        ))
    }

    func testReconcileDropsClosedAndNonTerminalSelections() {
        let windows = [window("terminal", app: "Terminal"), window("sim", app: "Simulator")]
        XCTAssertEqual(
            BroadcastPromptPlan.reconciledSelection(
                ["terminal", "closed", "sim"],
                windows: windows
            ),
            ["terminal"]
        )
    }

    func testFailedSelectionKeepsOnlyTargetsThatNeedRetry() {
        XCTAssertEqual(
            BroadcastPromptPlan.failedSelection(
                requestedIDs: ["one", "two", "three"],
                queuedIDs: ["one", "three"]
            ),
            ["two"]
        )
    }

    func testBroadcastActionRequiresConnectionAndATerminal() {
        let terminal = window("terminal", app: "iTerm2")
        let browser = window("browser", app: "Safari", targetKind: "browser_localhost")

        XCTAssertTrue(BroadcastPromptPlan.canOpen(windows: [terminal], isConnected: true))
        XCTAssertFalse(BroadcastPromptPlan.canOpen(windows: [terminal], isConnected: false))
        XCTAssertFalse(BroadcastPromptPlan.canOpen(windows: [browser], isConnected: true))
    }
}
