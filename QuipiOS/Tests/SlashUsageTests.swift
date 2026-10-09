import XCTest
@testable import Quip

/// The long-press slash palette lists the commands the user fires most first.
final class SlashUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let ids = ["b:plan", "b:compact", "b:clearContext", "b:resume"]

    private func ranked(_ store: PromptRanker.Store) -> [String] {
        SlashUsage.ranked(ids, id: { $0 }, store: store, at: now)
    }

    private func store(_ uses: [(String, Int)]) -> PromptRanker.Store {
        var s: PromptRanker.Store = [:]
        for (id, n) in uses {
            for _ in 0..<n { s = SlashUsage.recording(id, at: now, in: s) }
        }
        return s
    }

    func test_noUsageKeepsThePaletteOrder() {
        XCTAssertEqual(ranked([:]), ids)
    }

    func test_mostUsedCommandsComeFirst() {
        XCTAssertEqual(ranked(store([("b:resume", 3), ("b:compact", 1)])),
                       ["b:resume", "b:compact", "b:plan", "b:clearContext"])
    }

    func test_unusedCommandsKeepTheirOrderBelowUsedOnes() {
        XCTAssertEqual(ranked(store([("b:clearContext", 1)])),
                       ["b:clearContext", "b:plan", "b:compact", "b:resume"])
    }

    func test_recentUseOutranksOldUseOfTheSameCount() {
        var s = SlashUsage.recording("b:plan", at: now.addingTimeInterval(-30 * 24 * 3600), in: [:])
        s = SlashUsage.recording("b:resume", at: now, in: s)
        XCTAssertEqual(ranked(s).prefix(2), ["b:resume", "b:plan"])
    }

    func test_slashUsageLivesBesidePromptsWithoutTouchingThem() {
        let prompts = PromptRanker.recording("prompt-1", context: nil, at: now, in: [:])
        let s = SlashUsage.recording("b:plan", at: now, in: prompts)
        XCTAssertEqual(s["prompt-1"], prompts["prompt-1"])
        XCTAssertEqual(s["slash:b:plan"]?.uses, 1)
        XCTAssertNil(s["b:plan"], "slash keys are prefixed so they cannot collide with a prompt id")
    }

    func test_popularBuiltinsAreInThePalette() {
        let slash = QuickButton.allCases.filter(\.isSlashCommand)
        for b in [QuickButton.brainstorm, .writePlan, .executePlan, .resume, .model, .context] {
            XCTAssertTrue(slash.contains(b), "\(b) should be a slash command")
            XCTAssertEqual(b.category, .slash)
        }
        XCTAssertEqual(MainiOSView.SlashGroupMember.builtin(.brainstorm).sentText, "/superpowers:brainstorming")
    }
}
