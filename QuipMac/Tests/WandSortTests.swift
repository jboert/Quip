import XCTest
@testable import Quip

/// The wand's ordering rules and its rotation.
///
/// Worth pinning because the button's whole problem was that its behaviour was
/// not what anyone expected: it flipped every dev window off on the second tap,
/// and its "terminals" set silently included Terminal.app and simulators.
final class WandSortTests: XCTestCase {

    private func item(_ id: String, tier: Int = 0, subtitle: String = "",
                      waiting: Bool = false, active: Date? = nil) -> WandSortItem {
        WandSortItem(id: id, tier: tier, subtitle: subtitle,
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
}
