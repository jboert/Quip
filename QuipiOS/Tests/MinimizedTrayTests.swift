import XCTest
@testable import Quip

/// Q-53: the tray lists exactly the windows the Mac reports minimized.
final class MinimizedTrayTests: XCTestCase {
    private func window(_ id: String, name: String = "zsh", folder: String? = nil,
                        minimized: Bool, color: String = "#4A90E2") -> WindowState {
        WindowState(id: id, name: name, app: "iTerm2", folder: folder, enabled: true,
                    frame: WindowFrame(x: 0, y: 0, width: 1, height: 1),
                    state: "neutral", color: color, isMinimized: minimized)
    }

    func test_onlyMinimizedWindowsInTheMacsOrder() {
        let entries = MinimizedTray.entries([
            window("a", minimized: false),
            window("b", folder: "api", minimized: true, color: "#111111"),
            window("c", minimized: false),
            window("d", name: "Terminal", minimized: true),
        ])
        XCTAssertEqual(entries, [
            MinimizedTray.Entry(id: "b", title: "api", color: "#111111"),
            MinimizedTray.Entry(id: "d", title: "Terminal", color: "#4A90E2"),
        ])
    }

    func test_anEmptyFolderFallsBackToTheName() {
        let entries = MinimizedTray.entries([window("a", name: "build", folder: "", minimized: true)])
        XCTAssertEqual(entries.map(\.title), ["build"])
    }

    func test_nothingMinimizedMeansNoTray() {
        XCTAssertTrue(MinimizedTray.entries([window("a", minimized: false)]).isEmpty)
        XCTAssertTrue(MinimizedTray.entries([]).isEmpty)
    }
}
