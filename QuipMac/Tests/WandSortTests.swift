import XCTest
@testable import Quip

/// The wand's ordering rules and its rotation.
///
/// Worth pinning because the button's whole problem was that its behaviour was
/// not what anyone expected: it flipped every dev window off on the second tap,
/// and its "terminals" set silently included Terminal.app and simulators.
final class WandSortTests: XCTestCase {

    /// `kind` defaults to `.iterm2` so the existing cases keep meaning what they
    /// meant: a terminal, eligible for the waiting-for-input raise.
    private func item(_ id: String, tier: Int = 0, kind: WandWindowKind = .iterm2,
                      subtitle: String = "", waiting: Bool = false,
                      active: Date? = nil) -> WandSortItem {
        WandSortItem(id: id, kind: kind, tier: tier, subtitle: subtitle,
                     isWaitingForInput: waiting, lastOutputChangeAt: active)
    }

    // MARK: - devFocused

    func testDevFocusedPutsTerminalsThenSimulatorsThenRest() {
        let order = WandSort.order([
            item("other", tier: 2),
            item("sim", tier: 1),
            item("term", tier: 0)
        ], mode: .devFocused)

        XCTAssertEqual(order, ["term", "sim", "other"])
    }

    func testDevFocusedRaisesAWaitingTerminalWithinItsTier() {
        let order = WandSort.order([
            item("busy", tier: 0, subtitle: "a"),
            item("needsYou", tier: 0, subtitle: "z", waiting: true)
        ], mode: .devFocused)

        XCTAssertEqual(order, ["needsYou", "busy"],
                       "The window that needs you outranks the subtitle sort")
    }

    /// Waiting only reorders WITHIN the terminal tier here — a waiting
    /// non-terminal must not jump the whole list, which is what
    /// `.attentionFirst` is for.
    func testDevFocusedDoesNotLetAWaitingNonTerminalJumpTiers() {
        let order = WandSort.order([
            item("term", tier: 0),
            item("waitingOther", tier: 2, waiting: true)
        ], mode: .devFocused)

        XCTAssertEqual(order, ["term", "waitingOther"])
    }

    // MARK: - mostActive

    func testMostActiveSortsNewestOutputFirst() {
        let now = Date()
        let order = WandSort.order([
            item("old", active: now.addingTimeInterval(-60)),
            item("newest", active: now),
            item("middle", active: now.addingTimeInterval(-10))
        ], mode: .mostActive)

        XCTAssertEqual(order, ["newest", "middle", "old"])
    }

    /// The distinction the tracker exists to preserve: a window never observed
    /// to change is not one that changed long ago. Sorting nil as "the epoch"
    /// would be the same answer by accident here, but it would also mean a
    /// window that genuinely last moved in 1970 could never be told apart from
    /// one we simply have not looked at yet.
    func testNeverObservedWindowsSortLastNotFirst() {
        let now = Date()
        let order = WandSort.order([
            item("never", active: nil),
            item("ancient", active: now.addingTimeInterval(-86_400))
        ], mode: .mostActive)

        XCTAssertEqual(order, ["ancient", "never"])
    }

    func testMostActiveIgnoresTier() {
        let now = Date()
        let order = WandSort.order([
            item("term", tier: 0, active: now.addingTimeInterval(-60)),
            item("other", tier: 2, active: now)
        ], mode: .mostActive)

        XCTAssertEqual(order, ["other", "term"],
                       "Activity is the whole point of this mode — kind does not override it")
    }

    /// Regression for `af86695`: the tier now MOVES with the configuration, so
    /// under the default iTerm2 is tier 0 and Terminal.app is tier 1. The
    /// waiting raise was keyed on `tier == 0`, which silently stopped applying
    /// to Terminal.app windows the moment the tiers split.
    func testAWaitingTerminalAppWindowIsStillRaisedEvenThoughItIsNotTierZero() {
        let order = WandSort.order([
            item("busy", tier: 1, kind: .terminalApp, subtitle: "a"),
            item("needsYou", tier: 1, kind: .terminalApp, subtitle: "z", waiting: true)
        ], mode: .devFocused)

        XCTAssertEqual(order, ["needsYou", "busy"])
    }

    /// The raise belongs to terminals, not to whatever happens to rank first.
    /// Configure the wand for simulators only and they become tier 0 — a
    /// simulator has no prompt to wait at, so nothing should be raised.
    func testASimulatorAtTierZeroGetsNoWaitingRaise() {
        let order = WandSort.order([
            item("simA", tier: 0, kind: .simulator, subtitle: "a"),
            item("simB", tier: 0, kind: .simulator, subtitle: "z", waiting: true)
        ], mode: .devFocused)

        XCTAssertEqual(order, ["simA", "simB"],
                       "Subtitle decides; waiting is meaningless for a simulator")
    }

    // MARK: - mostActive with no data

    /// The common case, not an edge one: the activity signal only covers
    /// windows the mode poll reads, so on launch, for anything switched off,
    /// and for every simulator there is nothing to rank by. It must fall back
    /// to the dev-focused grouping rather than dressing an alphabetical list up
    /// as a ranking.
    func testMostActiveWithNoDataFallsBackToTheDevFocusedGrouping() {
        let order = WandSort.order([
            item("other", tier: 3, kind: .other, subtitle: "a"),
            item("sim", tier: 2, kind: .simulator, subtitle: "b"),
            item("term", tier: 0, kind: .iterm2, subtitle: "c")
        ], mode: .mostActive)

        XCTAssertEqual(order, ["term", "sim", "other"],
                       "Subtitle order would have been the exact reverse")
    }

    /// The fallback carries the waiting raise too — the tail of an unranked
    /// list should still surface the window that needs you.
    func testTheNoDataFallbackStillRaisesAWaitingTerminal() {
        let order = WandSort.order([
            item("busy", subtitle: "a"),
            item("needsYou", subtitle: "z", waiting: true)
        ], mode: .mostActive)

        XCTAssertEqual(order, ["needsYou", "busy"])
    }

    /// Windows WITH data still lead, and the dataless tail keeps its grouping
    /// behind them — the two rules must not fight.
    func testRankedWindowsLeadAndTheDatalessTailKeepsItsGrouping() {
        let now = Date()
        let order = WandSort.order([
            item("noDataOther", tier: 3, kind: .other, subtitle: "a"),
            item("noDataTerm", tier: 0, kind: .iterm2, subtitle: "b"),
            item("ranked", tier: 2, kind: .simulator, subtitle: "c", active: now)
        ], mode: .mostActive)

        XCTAssertEqual(order, ["ranked", "noDataTerm", "noDataOther"])
    }

    func testHasActivityDataReportsWhetherAnythingCanBeRanked() {
        XCTAssertFalse(WandSort.hasActivityData([item("a"), item("b")]))
        XCTAssertTrue(WandSort.hasActivityData([item("a"), item("b", active: Date())]))
    }

    // MARK: - attentionFirst

    func testAttentionFirstRaisesWaitingAcrossEveryTier() {
        let order = WandSort.order([
            item("term", tier: 0),
            item("waitingOther", tier: 2, waiting: true)
        ], mode: .attentionFirst)

        XCTAssertEqual(order, ["waitingOther", "term"])
    }

    // MARK: - Stability

    /// A button that reshuffles equal windows on every tap feels random. Equal
    /// items must keep their incoming order in every mode.
    func testEqualItemsKeepTheirIncomingOrderInEveryMode() {
        let items = [item("a"), item("b"), item("c")]
        for mode in WandSortMode.allCases {
            XCTAssertEqual(WandSort.order(items, mode: mode), ["a", "b", "c"], "\(mode)")
        }
    }

    func testSubtitleBreaksTiesBeforeIncomingOrder() {
        let order = WandSort.order([
            item("z", subtitle: "zeta"),
            item("a", subtitle: "alpha")
        ], mode: .devFocused)

        XCTAssertEqual(order, ["a", "z"])
    }

    // MARK: - Rotation

    func testAdvanceWrapsAroundTheRotation() {
        let rotation: [WandSortMode] = [.devFocused, .mostActive]
        XCTAssertEqual(WandSort.advance(index: 0, rotation: rotation), 1)
        XCTAssertEqual(WandSort.advance(index: 1, rotation: rotation), 0)
    }

    /// The stored index outlives the stored rotation: shorten the rotation in
    /// Settings and the old index can point past the end. It must come back to
    /// a real mode rather than trapping the wand or crashing.
    func testAnIndexPastAShortenedRotationStillResolves() {
        let rotation: [WandSortMode] = [.devFocused]
        XCTAssertEqual(WandSort.mode(at: 5, rotation: rotation), .devFocused)
        XCTAssertEqual(WandSort.advance(index: 5, rotation: rotation), 0)
    }

    func testAnEmptyRotationCannotCrashOrStall() {
        XCTAssertEqual(WandSort.mode(at: 3, rotation: []), .devFocused)
        XCTAssertEqual(WandSort.advance(index: 3, rotation: []), 0)
    }

    // MARK: - Stored preferences

    func testStoredRotationRoundTrips() {
        let modes: [WandSortMode] = [.mostActive, .devFocused]
        XCTAssertEqual(WandSortMode.rotation(fromStored: WandSortMode.stored(modes)), modes)
    }

    /// A rotation that parses to nothing — every id removed in a later build,
    /// or a corrupt value — must not leave the wand unable to sort at all.
    func testUnknownStoredModesFallBackToTheFullRotation() {
        XCTAssertEqual(WandSortMode.rotation(fromStored: "nope,gone"), WandSortMode.allCases)
        XCTAssertEqual(WandSortMode.rotation(fromStored: ""), WandSortMode.allCases)
    }

    func testUnknownModesAreDroppedRatherThanDefaulted() {
        XCTAssertEqual(WandSortMode.rotation(fromStored: "mostActive,bogus"), [.mostActive],
                       "An unknown id must not silently become some other mode")
    }

    // MARK: - Target kinds

    func testDefaultTargetsMatchTheHistoricalBehaviour() {
        XCTAssertTrue(WandTargetKinds.default.contains(.iterm2))
        XCTAssertTrue(WandTargetKinds.default.contains(.terminalApp))
        XCTAssertTrue(WandTargetKinds.default.contains(.simulator))
    }

    /// An empty selection would make the wand enable nothing and read as a dead
    /// button. The setting narrows what it acts on; it is not an off switch.
    func testAnEmptyStoredSelectionFallsBackToTheDefault() {
        XCTAssertEqual(WandTargetKinds.fromStored(0), .default)
    }

    func testANarrowedSelectionIsHonoured() {
        let onlyITerm = WandTargetKinds.fromStored(WandTargetKinds.iterm2.rawValue)
        XCTAssertTrue(onlyITerm.contains(.iterm2))
        XCTAssertFalse(onlyITerm.contains(.terminalApp))
        XCTAssertFalse(onlyITerm.contains(.simulator))
    }

    // MARK: - Tier derivation follows the configured kinds

    /// The bug this closes: `WandTargetKinds` governed which windows the wand
    /// SWITCHES ON, while the sort still used a hardcoded table where
    /// `isTerminal` (iTerm2 OR Terminal.app) was one tier. Narrow the wand to
    /// iTerm2 and Terminal.app windows still rose above your simulators — they
    /// just did not get enabled. One setting, two meanings.
    func testAnUnconfiguredTerminalAppSinksBelowAConfiguredSimulator() {
        // The reported case: the wand is set to iTerm2 + simulators, so
        // Terminal.app windows must stop leading the list. Under the old fixed
        // table `isTerminal` made them tier 0 regardless.
        let configured: WandTargetKinds = [.iterm2, .simulator]
        XCTAssertEqual(WandSort.tier(of: .iterm2, configured: configured), 0)
        XCTAssertEqual(WandSort.tier(of: .simulator, configured: configured), 1)
        XCTAssertLessThan(WandSort.tier(of: .simulator, configured: configured),
                          WandSort.tier(of: .terminalApp, configured: configured),
                          "Terminal.app is not configured, so it must not outrank a simulator")
    }

    /// Narrowing to iTerm2 alone leaves Terminal.app and simulators both
    /// unconfigured. Their order relative to each OTHER is a don't-care; what
    /// matters is that neither ties with iTerm2 any more.
    func testNarrowingToIterm2DemotesEveryOtherKindBelowIt() {
        let configured: WandTargetKinds = [.iterm2]
        let iterm = WandSort.tier(of: .iterm2, configured: configured)
        XCTAssertEqual(iterm, 0)
        for kind in [WandWindowKind.terminalApp, .simulator, .other] {
            XCTAssertGreaterThan(WandSort.tier(of: kind, configured: configured), iterm,
                                 "\(kind) must not tie with or outrank the only configured kind")
        }
    }

    /// Configured kinds rank in declaration order so the result is predictable
    /// rather than dependent on which bit happens to be set.
    func testConfiguredKindsRankInDeclarationOrder() {
        let configured: WandTargetKinds = [.simulator, .terminalApp]
        XCTAssertEqual(WandSort.tier(of: .terminalApp, configured: configured), 0)
        XCTAssertEqual(WandSort.tier(of: .simulator, configured: configured), 1)
    }

    /// An unconfigured window is not excluded from the ordering, only demoted —
    /// the sidebar still lists it, so it still needs a defined position.
    func testUnconfiguredKindsKeepTheirRelativeOrderBelowConfiguredOnes() {
        let configured: WandTargetKinds = [.simulator]
        XCTAssertEqual(WandSort.tier(of: .simulator, configured: configured), 0)
        XCTAssertEqual(WandSort.tier(of: .iterm2, configured: configured), 1)
        XCTAssertEqual(WandSort.tier(of: .terminalApp, configured: configured), 2)
    }

    /// `.other` is always last: it is the one kind the setting can never name.
    func testOtherIsAlwaysLast() {
        for configured: WandTargetKinds in [[.iterm2], [.simulator], .default, []] {
            let other = WandSort.tier(of: .other, configured: configured)
            for kind in [WandWindowKind.iterm2, .terminalApp, .simulator] {
                XCTAssertLessThan(WandSort.tier(of: kind, configured: configured), other,
                                  "\(kind) must outrank .other for \(configured.rawValue)")
            }
        }
    }

    /// The default install must keep the ordering it has always had:
    /// terminals, then simulators, then everything else.
    func testDefaultKeepsTerminalsAboveSimulatorsAboveRest() {
        let d = WandTargetKinds.default
        XCTAssertLessThan(WandSort.tier(of: .iterm2, configured: d),
                          WandSort.tier(of: .simulator, configured: d))
        XCTAssertLessThan(WandSort.tier(of: .terminalApp, configured: d),
                          WandSort.tier(of: .simulator, configured: d))
        XCTAssertLessThan(WandSort.tier(of: .simulator, configured: d),
                          WandSort.tier(of: .other, configured: d))
    }
}

/// The activity signal behind `.mostActive`.
final class OutputActivityTrackerTests: XCTestCase {

    /// Seeding must not stamp activity. Every window is new at once on launch,
    /// and stamping here would rank the whole desk as maximally active — the
    /// exact opposite of what the mode is for.
    @MainActor
    func testFirstSightSeedsWithoutStampingActivity() {
        let tracker = OutputActivityTracker()
        XCTAssertFalse(tracker.record(windowId: "w1", content: "hello"))
        XCTAssertNil(tracker.lastOutputChangeAt["w1"])
    }

    @MainActor
    func testChangedContentStampsActivity() {
        let tracker = OutputActivityTracker()
        let now = Date()
        tracker.record(windowId: "w1", content: "hello", now: now)

        XCTAssertTrue(tracker.record(windowId: "w1", content: "hello world",
                                     now: now.addingTimeInterval(2)))
        XCTAssertEqual(tracker.lastOutputChangeAt["w1"], now.addingTimeInterval(2))
    }

    /// An agent sitting at a prompt redraws the same buffer forever. That is
    /// not activity, and treating it as such would make every idle window tie
    /// with the one actually working.
    @MainActor
    func testUnchangedContentDoesNotStamp() {
        let tracker = OutputActivityTracker()
        let now = Date()
        tracker.record(windowId: "w1", content: "same", now: now)
        tracker.record(windowId: "w1", content: "same", now: now.addingTimeInterval(2))
        XCTAssertNil(tracker.lastOutputChangeAt["w1"])

        tracker.record(windowId: "w1", content: "different", now: now.addingTimeInterval(4))
        XCTAssertEqual(tracker.lastOutputChangeAt["w1"], now.addingTimeInterval(4))
    }

    @MainActor
    func testWindowsAreTrackedIndependently() {
        let tracker = OutputActivityTracker()
        let now = Date()
        tracker.record(windowId: "w1", content: "a", now: now)
        tracker.record(windowId: "w2", content: "a", now: now)

        tracker.record(windowId: "w1", content: "b", now: now.addingTimeInterval(1))

        XCTAssertEqual(tracker.lastOutputChangeAt["w1"], now.addingTimeInterval(1))
        XCTAssertNil(tracker.lastOutputChangeAt["w2"],
                     "A shared hash table would have let w1's change stamp w2")
    }

    @MainActor
    func testPruneDropsUntrackedWindowsAndTheirSeeds() {
        let tracker = OutputActivityTracker()
        let now = Date()
        tracker.record(windowId: "gone", content: "a", now: now)
        tracker.record(windowId: "gone", content: "b", now: now.addingTimeInterval(1))
        tracker.record(windowId: "kept", content: "a", now: now)

        tracker.prune(toTracked: ["kept"])
        XCTAssertNil(tracker.lastOutputChangeAt["gone"])

        // The seed went too: a window that comes back is a first sight again,
        // not a change against a hash from before it was untracked.
        XCTAssertFalse(tracker.record(windowId: "gone", content: "c",
                                      now: now.addingTimeInterval(2)))
    }
    // MARK: - selection(for:kinds:) — the wand as an assignment, not an append

    private func item(_ id: String, _ kind: WandWindowKind, enabled: Bool) -> WandSelectionItem {
        WandSelectionItem(id: id, kind: kind, isEnabled: enabled)
    }

    /// The reported case: Simulators unchecked, yet simulator windows stay
    /// switched on forever.
    ///
    /// `magicSort` only ever ENABLED its targets, and `wandTargets()` filters to
    /// the configured kinds — so an unchecked kind was not "switch this off", it
    /// was "the wand cannot see this at all". Option-click could not clear them
    /// either, because it filters by the same configured kinds. Nothing in the
    /// wand could turn a simulator off once something else had turned it on.
    func testUncheckingSimulatorsSwitchesRunningSimulatorsOff() {
        let result = WandSort.selection(
            for: [item("term", .iterm2, enabled: false),
                  item("sim", .simulator, enabled: true)],
            kinds: [.iterm2, .terminalApp])
        XCTAssertEqual(result.enable, ["term"])
        XCTAssertEqual(result.disable, ["sim"])
    }

    /// A tap lands on exactly the checked kinds — so tapping again changes
    /// nothing. This is what keeps the assignment from being the old toggle,
    /// whose second tap ended with nothing selected and read as a dead button.
    func testASecondTapIsANoOp() {
        let settled = [item("term", .iterm2, enabled: true),
                       item("sim", .simulator, enabled: false)]
        let result = WandSort.selection(for: settled, kinds: [.iterm2])
        XCTAssertEqual(result.enable, [])
        XCTAssertEqual(result.disable, [])
    }

    /// `other` has no `WandTargetKinds` counterpart, so the setting can never
    /// name it — which means the wand must never switch it off either. A
    /// browser the user enabled by hand is not the wand's business.
    func testWindowsTheWandCannotNameAreLeftAlone() {
        let result = WandSort.selection(
            for: [item("chrome", .other, enabled: true),
                  item("finder", .other, enabled: false)],
            kinds: [.iterm2])
        XCTAssertEqual(result.enable, [])
        XCTAssertEqual(result.disable, [])
    }

    /// Only actual changes are reported, so the caller does not write a
    /// toggle — and an animation block — for a window already in the right
    /// state.
    func testAlreadyCorrectWindowsAreNotReported() {
        let result = WandSort.selection(
            for: [item("a", .iterm2, enabled: true), item("b", .simulator, enabled: false)],
            kinds: [.iterm2])
        XCTAssertEqual(result.enable, [])
        XCTAssertEqual(result.disable, [])
    }

    func testEveryConfiguredKindIsSwitchedOn() {
        let result = WandSort.selection(
            for: [item("a", .iterm2, enabled: false),
                  item("b", .terminalApp, enabled: false),
                  item("c", .simulator, enabled: false)],
            kinds: [.iterm2, .terminalApp, .simulator])
        XCTAssertEqual(result.enable, ["a", "b", "c"])
        XCTAssertEqual(result.disable, [])
    }

    /// An empty stored set falls back to the default rather than switching the
    /// whole desk off — the same defence `fromStored` already applies, checked
    /// here because under an assignment model the blast radius of getting it
    /// wrong is now "everything turns off" rather than "nothing turns on".
    func testACorruptEmptyKindSetDoesNotSwitchEverythingOff() {
        let result = WandSort.selection(
            for: [item("a", .iterm2, enabled: true), item("c", .simulator, enabled: true)],
            kinds: WandTargetKinds.fromStored(0))
        XCTAssertEqual(result.disable, [])
    }

}
