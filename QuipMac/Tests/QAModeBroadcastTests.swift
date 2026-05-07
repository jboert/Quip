import XCTest
import CoreGraphics
@testable import Quip

/// Pure-functional QA-mode tests: filter behavior + ID-set semantics.
/// Connection-level tests stay manual (NWConnection requires a real socket).
@MainActor
final class QAModeBroadcastTests: XCTestCase {

    private func mw(id: String, bundleId: String, enabled: Bool, onScreen: Bool = true) -> ManagedWindow {
        ManagedWindow(
            id: id, name: id, app: bundleId, subtitle: "",
            bundleId: bundleId, icon: nil, isEnabled: enabled,
            assignedColor: "#F5A623", pid: 1, windowNumber: 0,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            iterm2SessionId: nil, isOnVisibleScreen: onScreen
        )
    }

    func testQAPairFilterReturnsOnlyTwoIds() {
        let all = [
            mw(id: "sim", bundleId: "com.apple.iphonesimulator", enabled: false),
            mw(id: "term", bundleId: "com.googlecode.iterm2", enabled: false),
            mw(id: "noise1", bundleId: "com.googlecode.iterm2", enabled: true),
            mw(id: "noise2", bundleId: "com.apple.Safari", enabled: true),
        ]
        let result = WindowManager.windowsForBroadcast(
            all, mirrorDesktop: true, qaPair: ("sim", "term")
        )
        XCTAssertEqual(Set(result.map(\.id)), Set(["sim", "term"]))
    }

    func testManagedWindowIsTargetForSimulator() {
        let sim = mw(id: "1", bundleId: "com.apple.iphonesimulator", enabled: false)
        XCTAssertTrue(sim.isTarget)
        XCTAssertEqual(sim.targetKind, "simulator")
    }

    func testManagedWindowIsNotTargetForTerminal() {
        let term = mw(id: "1", bundleId: "com.googlecode.iterm2", enabled: false)
        XCTAssertFalse(term.isTarget)
        XCTAssertNil(term.targetKind)
    }

    func testManagedWindowIsNotTargetForBrowser() {
        // v1 — browsers don't qualify yet. Documents the v2 deferral.
        let safari = mw(id: "1", bundleId: "com.apple.Safari", enabled: true)
        XCTAssertFalse(safari.isTarget)
        XCTAssertNil(safari.targetKind)
    }

    func testToWindowStateIncludesTargetKind() {
        let sim = mw(id: "1", bundleId: "com.apple.iphonesimulator", enabled: false)
        let state = sim.toWindowState(state: "neutral",
                                      screenBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(state.targetKind, "simulator")
    }

    func testToWindowStateOmitsTargetKindForNonTarget() {
        let term = mw(id: "1", bundleId: "com.googlecode.iterm2", enabled: false)
        let state = term.toWindowState(state: "neutral",
                                       screenBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(state.targetKind)
    }
}
