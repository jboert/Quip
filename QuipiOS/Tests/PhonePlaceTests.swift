import XCTest
@testable import Quip

/// Q-88 US-005: "where I was" for one Mac, saved on the phone only.
@MainActor
final class PhonePlaceTests: XCTestCase {
    private let suite = "PhonePlaceTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private let place = PhonePlace(selectedWindowId: "com.googlecode.iterm2.4117", selectedDisplayID: "2",
                                   selectedSpaceID: "s3", textInputOpen: true, terminalExpanded: true,
                                   scrollAnchorByWindow: ["w": ScrollAnchor(line: "$ make test", fromEnd: 40)],
                                   savedAt: Date(timeIntervalSince1970: 1_800_000_000))

    // MARK: Store

    func test_roundTrip_perBackend() {
        var logs: [String] = []
        PhonePlaceStore.save(place, forBackendId: "mac-a", defaults: defaults) { logs.append($0) }
        XCTAssertEqual(PhonePlaceStore.load(forBackendId: "mac-a", defaults: defaults) { logs.append($0) }, place)
        XCTAssertNil(PhonePlaceStore.load(forBackendId: "mac-b", defaults: defaults) { logs.append($0) })
        XCTAssertTrue(logs.isEmpty, "a saved place, or none yet, is not an error: \(logs)")
    }

    func test_unknownFutureKeys_areIgnored_andMissingFlagsReadAsClosed() throws {
        let json = #"{"savedAt":0,"selectedWindowId":"w","layoutVersion":7,"scrollAnchorByWindow":{}}"#
        defaults.set(Data(json.utf8), forKey: PhonePlaceStore.key(forBackendId: "mac"))
        let read = try XCTUnwrap(PhonePlaceStore.load(forBackendId: "mac", defaults: defaults) { XCTFail($0) })
        XCTAssertEqual(read.selectedWindowId, "w")
        XCTAssertFalse(read.textInputOpen)
        XCTAssertFalse(read.terminalExpanded)
    }

    func test_corruptData_isNil_withOneLogLine() {
        defaults.set(Data("{ not json".utf8), forKey: PhonePlaceStore.key(forBackendId: "mac"))
        var logs: [String] = []
        XCTAssertNil(PhonePlaceStore.load(forBackendId: "mac", defaults: defaults) { logs.append($0) })
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs.first?.contains("phonePlace decode FAILED") ?? false, "\(logs)")
    }

    func test_awayFor() {
        XCTAssertNil(PhonePlaceStore.awayFor(now: Date(), defaults: defaults), "never backgrounded")
        let left = Date(timeIntervalSince1970: 1_800_000_000)
        PhonePlaceStore.markBackgrounded(at: left, defaults: defaults)
        XCTAssertEqual(PhonePlaceStore.awayFor(now: left.addingTimeInterval(90), defaults: defaults), 90)
        XCTAssertNil(PhonePlaceStore.awayFor(now: left.addingTimeInterval(-5), defaults: defaults),
                     "a clock that went backwards is no answer")
    }

    // MARK: Recorder

    private final class Rig {
        var writes: [(String, PhonePlace)] = []
        var timers: [(TimeInterval, () -> Void)] = []
    }

    private func recorder(_ rig: Rig) -> PhonePlaceRecorder {
        PhonePlaceRecorder(persist: { rig.writes.append(($1, $0)) },
                           schedule: { rig.timers.append(($0, $1)) })
    }

    func test_manyChangesInASecond_makeOneWriteOfTheLatest() {
        let rig = Rig()
        let r = recorder(rig)
        var a = place; a.selectedWindowId = "a"
        var b = place; b.selectedWindowId = "b"
        r.record(a, forBackendId: "mac")
        r.record(b, forBackendId: "mac")
        XCTAssertTrue(rig.writes.isEmpty)
        XCTAssertEqual(rig.timers.map(\.0), [1])
        rig.timers[0].1()
        XCTAssertEqual(rig.writes.map(\.1.selectedWindowId), ["b"])
    }

    func test_flushAll_writesAtOnce_andTheLateTimerWritesNothingMore() {
        let rig = Rig()
        let r = recorder(rig)
        r.record(place, forBackendId: "mac")
        r.flushAll()
        XCTAssertEqual(rig.writes.count, 1)
        rig.timers.forEach { $0.1() }
        XCTAssertEqual(rig.writes.count, 1)
    }

    func test_noBackend_recordsNothing() {
        let rig = Rig()
        let r = recorder(rig)
        r.record(place, forBackendId: "")
        r.flushAll()
        XCTAssertTrue(rig.writes.isEmpty)
    }

    // MARK: Device-local

    func test_placeNeverReachesTheBackup() throws {
        let names = Mirror(reflecting: PreferencesSnapshot()).children.compactMap(\.label)
        for field in ["phonePlace", "selectedWindowId", "selectedDisplayID", "selectedSpaceID", "textInputOpen",
                      "terminalExpanded", "scrollAnchorByWindow", "backgroundedAt"] {
            XCTAssertFalse(names.contains { $0.localizedCaseInsensitiveContains(field) }, "\(field) is in the backup")
        }
        // And a saved place does not leak in through the defaults the backup reads.
        PhonePlaceStore.save(place, forBackendId: "mac", defaults: defaults)
        PhonePlaceStore.markBackgrounded(at: Date(), defaults: defaults)
        let blob = try JSONEncoder().encode(PreferencesSyncService.snapshot(from: defaults, savedAt: 1))
        let text = String(decoding: blob, as: UTF8.self)
        XCTAssertFalse(text.contains("4117") || text.contains("make test"), text)
    }
}
