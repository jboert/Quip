import XCTest
@testable import Quip

@MainActor
final class VibeCutIDMapTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibecut-ids-\(UUID().uuidString)", isDirectory: true)
        VibeCutSyncService.idMapURLOverrideForTests = tmp.appendingPathComponent("vibecut-ids.json")
    }

    override func tearDown() {
        VibeCutSyncService.idMapURLOverrideForTests = nil
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    func testMissingFileLoadsEmpty() {
        XCTAssertEqual(VibeCutSyncService.loadIDMap(), [:])
    }

    func testSaveThenLoadRoundTripsAndCreatesDirectory() throws {
        let map = ["p1": "vibecut__commit", "p2": "vibecut__review"]
        try VibeCutSyncService.saveIDMap(map)
        XCTAssertEqual(VibeCutSyncService.loadIDMap(), map)
    }

    func testCorruptFileLoadsEmpty() throws {
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: VibeCutSyncService.idMapURL)
        XCTAssertEqual(VibeCutSyncService.loadIDMap(), [:])
    }
}
