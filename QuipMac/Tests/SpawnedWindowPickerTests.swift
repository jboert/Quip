import XCTest
@testable import Quip

final class SpawnedWindowPickerTests: XCTestCase {

    // MARK: - Single-spawn happy path

    func test_singleSpawn_picksNewTerminalWindow() {
        let result = SpawnedWindowPicker.pick(
            currentIds: ["a", "b", "newTerm"],
            knownIds: ["a", "b"],
            claimed: [],
            candidates: [
                .init(id: "a", isTerminal: true),
                .init(id: "b", isTerminal: true),
                .init(id: "newTerm", isTerminal: true),
            ]
        )
        XCTAssertEqual(result.pickedId, "newTerm")
    }

    func test_singleSpawn_prefersTerminalOverNonTerminalNewcomer() {
        let result = SpawnedWindowPicker.pick(
            currentIds: ["a", "stray", "newTerm"],
            knownIds: ["a"],
            claimed: [],
            candidates: [
                .init(id: "a", isTerminal: true),
                .init(id: "stray", isTerminal: false),
                .init(id: "newTerm", isTerminal: true),
            ]
        )
        XCTAssertEqual(result.pickedId, "newTerm",
                       "non-terminal new window must lose to terminal one in the same refresh tick")
    }

    func test_singleSpawn_fallsBackToNonTerminalIfNoTerminalIsNew() {
        let result = SpawnedWindowPicker.pick(
            currentIds: ["a", "stray"],
            knownIds: ["a"],
            claimed: [],
            candidates: [
                .init(id: "a", isTerminal: true),
                .init(id: "stray", isTerminal: false),
            ]
        )
        XCTAssertEqual(result.pickedId, "stray",
                       "if no terminal new window appeared, pick whatever is new")
    }

    // MARK: - The race-A scenario

    func test_threeRapidSpawns_picksDistinctWindowsViaClaimed() {
        // Three spawns fire inside 2s. All three pollers captured `knownIds = {a, b}`.
        // First poller runs when iTerm has finished spawning ALL THREE new windows.
        var claimed: Set<String> = []
        let candidates: [SpawnedWindowPicker.Candidate] = [
            .init(id: "a", isTerminal: true),
            .init(id: "b", isTerminal: true),
            .init(id: "spawn1", isTerminal: true),
            .init(id: "spawn2", isTerminal: true),
            .init(id: "spawn3", isTerminal: true),
        ]
        let currentIds: Set<String> = ["a", "b", "spawn1", "spawn2", "spawn3"]
        let knownIds: Set<String> = ["a", "b"]

        // Poller 1 picks one of the three.
        let r1 = SpawnedWindowPicker.pick(currentIds: currentIds,
                                           knownIds: knownIds,
                                           claimed: claimed,
                                           candidates: candidates)
        XCTAssertNotNil(r1.pickedId)
        claimed.insert(r1.pickedId!)

        // Poller 2 must NOT pick the one Poller 1 claimed.
        let r2 = SpawnedWindowPicker.pick(currentIds: currentIds,
                                           knownIds: knownIds,
                                           claimed: claimed,
                                           candidates: candidates)
        XCTAssertNotNil(r2.pickedId)
        XCTAssertNotEqual(r2.pickedId, r1.pickedId,
                          "poller 2 must NOT pick poller 1's claimed id")
        claimed.insert(r2.pickedId!)

        // Poller 3 picks the remaining new window.
        let r3 = SpawnedWindowPicker.pick(currentIds: currentIds,
                                           knownIds: knownIds,
                                           claimed: claimed,
                                           candidates: candidates)
        XCTAssertNotNil(r3.pickedId)
        XCTAssertNotEqual(r3.pickedId, r1.pickedId)
        XCTAssertNotEqual(r3.pickedId, r2.pickedId)

        // All three picks together cover the three new ids exactly.
        let picked = Set([r1.pickedId, r2.pickedId, r3.pickedId].compactMap { $0 })
        XCTAssertEqual(picked, ["spawn1", "spawn2", "spawn3"])
    }

    // MARK: - Nothing-yet retry path

    func test_noNewWindowsYet_returnsNil() {
        let result = SpawnedWindowPicker.pick(
            currentIds: ["a", "b"],
            knownIds: ["a", "b"],
            claimed: [],
            candidates: [
                .init(id: "a", isTerminal: true),
                .init(id: "b", isTerminal: true),
            ]
        )
        XCTAssertNil(result.pickedId,
                     "with no new ids, picker must return nil so caller retries")
    }

    func test_onlyClaimedNewIds_returnsNil() {
        // Edge case: poller fires AFTER another poller already claimed the
        // only new id. Should defer (return nil) so the calling code retries
        // when the next iTerm spawn lands.
        let result = SpawnedWindowPicker.pick(
            currentIds: ["a", "spawn1"],
            knownIds: ["a"],
            claimed: ["spawn1"],
            candidates: [
                .init(id: "a", isTerminal: true),
                .init(id: "spawn1", isTerminal: true),
            ]
        )
        XCTAssertNil(result.pickedId,
                     "every new id is already claimed by an earlier poller — must retry")
    }

    // MARK: - Unknown candidate metadata

    func test_unknownCandidateId_treatedAsNonTerminal() {
        // If WindowManager broadcasts an id for which no candidate metadata
        // is supplied (race in caller's snapshotting), the picker shouldn't
        // crash — it just treats unknown ids as non-terminal.
        let result = SpawnedWindowPicker.pick(
            currentIds: ["a", "newGhost"],
            knownIds: ["a"],
            claimed: [],
            candidates: [
                .init(id: "a", isTerminal: true),
            ]
        )
        XCTAssertEqual(result.pickedId, "newGhost",
                       "unknown candidate id is still picked as fallback")
    }
}
