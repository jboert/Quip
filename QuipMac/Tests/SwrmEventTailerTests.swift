import XCTest
@testable import Quip

/// US-001: the swrm event-log reader contract + cursor store. We test the
/// pure reader seam (`SwrmEventReader.readIncremental`) and the cursor store
/// directly — the same "testable seam" swrm's own reader is built around —
/// rather than the async `SwrmEventTailer` pump, so assertions stay
/// deterministic (no DispatchQueue timing).
final class SwrmEventTailerTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swrm-tailer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        SwrmCursorStore.directoryOverrideForTests = nil
    }

    // MARK: helpers

    private func writeFile(_ contents: String) -> URL {
        let url = tmpDir.appendingPathComponent("events.ndjson")
        try! contents.data(using: .utf8)!.write(to: url)
        return url
    }

    private func line(seq: Int, type: String, id: String, to: String? = nil, title: String? = nil) -> String {
        var data: [String: Any] = [:]
        if let to { data["to"] = to }
        if let title { data["title"] = title }
        let obj: [String: Any] = [
            "seq": seq, "v": 1, "ts": "2026-06-05T00:00:0\(seq)Z",
            "type": type, "actor": "user",
            "aggregate": ["type": "task", "id": id],
            "data": data,
        ]
        let bytes = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: bytes, encoding: .utf8)!
    }

    // MARK: reader — torn last line + advancing cursor

    func test_readIncremental_holdsBackTornLastLine_thenDeliversWhenComplete() {
        // Two complete lines + a torn (incomplete) trailing third line: the
        // torn line has NO newline terminator, so the reader must hold it back.
        let complete1 = line(seq: 1, type: "task.created", id: "7", title: "Wire the spine")
        let complete2 = line(seq: 2, type: "task.planned", id: "7")
        let torn = String(line(seq: 3, type: "task.moved", id: "7", to: "in_progress").prefix(20))
        let url = writeFile(complete1 + "\n" + complete2 + "\n" + torn) // no trailing \n

        let first = SwrmEventReader.readIncremental(fileURL: url, byteOffset: 0, since: 0)

        XCTAssertEqual(first.events.map(\.seq), [1, 2], "only the two complete lines deliver")
        XCTAssertEqual(first.events.first?.data.title, "Wire the spine")
        // nextOffset must stop at the boundary AFTER complete2's newline — it
        // must NOT consume the torn bytes.
        let boundary = (complete1 + "\n" + complete2 + "\n").utf8.count
        XCTAssertEqual(first.nextOffset, boundary, "cursor stops at last complete-line boundary")

        // The torn line finishes and a fourth event arrives — i.e. the log
        // grows to its complete form. Re-read from the held-back cursor: the
        // previously-torn line now delivers whole, with no replay of seq 1/2.
        let full3 = line(seq: 3, type: "task.moved", id: "7", to: "in_progress")
        let complete4 = line(seq: 4, type: "task.completed", id: "7")
        let fullURL = writeFile(complete1 + "\n" + complete2 + "\n" + full3 + "\n" + complete4 + "\n")

        let second = SwrmEventReader.readIncremental(
            fileURL: fullURL, byteOffset: first.nextOffset, since: first.events.last!.seq)

        XCTAssertEqual(second.events.map(\.seq), [3, 4], "torn line now whole + the new line; no replay")
        XCTAssertEqual(second.events.first?.data.to, "in_progress")
        let eof = (try! Data(contentsOf: fullURL)).count
        XCTAssertEqual(second.nextOffset, eof, "cursor reaches EOF after a clean trailing newline")
    }

    func test_readIncremental_seqGate_preventsDoubleDelivery() {
        let l1 = line(seq: 1, type: "task.created", id: "1", title: "A")
        let l2 = line(seq: 2, type: "task.created", id: "2", title: "B")
        let url = writeFile(l1 + "\n" + l2 + "\n")

        // Re-read from byteOffset 0 but with `since: 2`: byte cursor would
        // re-surface both lines, but the seq gate drops them.
        let r = SwrmEventReader.readIncremental(fileURL: url, byteOffset: 0, since: 2)
        XCTAssertTrue(r.events.isEmpty, "seq gate suppresses already-delivered events")
    }

    func test_readIncremental_missingFile_isNoOp() {
        let url = tmpDir.appendingPathComponent("does-not-exist.ndjson")
        let r = SwrmEventReader.readIncremental(fileURL: url, byteOffset: 0, since: 0)
        XCTAssertTrue(r.events.isEmpty)
        XCTAssertEqual(r.nextOffset, 0, "missing file leaves the cursor untouched")
    }

    func test_read_fullSlurp_parsesAggregateAndData() {
        let url = writeFile(
            line(seq: 1, type: "task.created", id: "42", title: "Tail the log") + "\n")
        let events = SwrmEventReader.read(fileURL: url)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].aggregateType, "task")
        XCTAssertEqual(events[0].aggregateID, "42")
        XCTAssertEqual(events[0].data.title, "Tail the log")
    }

    // MARK: cursor store

    func test_cursorStore_roundTrips() {
        SwrmCursorStore.directoryOverrideForTests =
            tmpDir.appendingPathComponent("cursors", isDirectory: true)
        let root = "/Users/me/Projects/swrm"

        XCTAssertEqual(SwrmCursorStore.load(forRootPath: root), .zero, "missing cursor → zero")

        SwrmCursorStore.save(SwrmCursor(byteOffset: 128, seq: 9), forRootPath: root)
        XCTAssertEqual(SwrmCursorStore.load(forRootPath: root), SwrmCursor(byteOffset: 128, seq: 9))
    }

    func test_cursorStore_distinctRootsDoNotCollide() {
        let a = SwrmCursorStore.filename(forRootPath: "/Users/me/Projects/alpha")
        let b = SwrmCursorStore.filename(forRootPath: "/Users/me/Projects/beta")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasSuffix(".json"))
        XCTAssertFalse(a.hasPrefix("_"), "leading separators stripped")
    }

    // MARK: title cache (US-003)

    /// Write an `.ndjson` log into `<tmpDir>/.swrm/events.ndjson` so a tailer
    /// rooted at `tmpDir` can seed from it (file-only, no SQLite).
    private func writeProjectLog(_ contents: String) {
        let swrm = tmpDir.appendingPathComponent(".swrm", isDirectory: true)
        try! FileManager.default.createDirectory(at: swrm, withIntermediateDirectories: true)
        try! contents.data(using: .utf8)!.write(
            to: swrm.appendingPathComponent("events.ndjson"))
    }

    @MainActor
    func test_titleCache_createdThenMoved_resolvesTitle() {
        // task.created carries the title; task.moved (in_progress) carries none.
        writeProjectLog(
            line(seq: 1, type: "task.created", id: "5", title: "Wire the spine") + "\n" +
            line(seq: 2, type: "task.moved", id: "5", to: "in_progress") + "\n")

        let tailer = SwrmEventTailer(projectRoot: tmpDir)
        let seeded = tailer.seedTitleCache()

        XCTAssertEqual(seeded, 1, "one title learned from history")
        XCTAssertEqual(tailer.resolvedTitle(forAggregateID: "5"), "Wire the spine",
                       "moved event's title comes from the cached created event")
    }

    @MainActor
    func test_titleCache_plannedSeedsTitle() {
        // task.planned also carries data.title.
        writeProjectLog(line(seq: 1, type: "task.planned", id: "8", title: "Plan it") + "\n")

        let tailer = SwrmEventTailer(projectRoot: tmpDir)
        tailer.seedTitleCache()

        XCTAssertEqual(tailer.resolvedTitle(forAggregateID: "8"), "Plan it")
    }

    @MainActor
    func test_titleCache_movedWithoutPriorCreated_fallsBackToStoryID() {
        // A moved event whose created was never seen → fallback, never blank.
        writeProjectLog(line(seq: 1, type: "task.moved", id: "99", to: "in_progress") + "\n")

        let tailer = SwrmEventTailer(projectRoot: tmpDir)
        tailer.seedTitleCache()

        XCTAssertTrue(tailer.titleCache.isEmpty, "moved carries no title to cache")
        XCTAssertEqual(tailer.resolvedTitle(forAggregateID: "99"), "Story #99")
    }

    @MainActor
    func test_titleCache_unknownAggregate_fallsBackToStoryID() {
        let tailer = SwrmEventTailer(projectRoot: tmpDir)
        XCTAssertEqual(tailer.resolvedTitle(forAggregateID: "123"), "Story #123",
                       "empty cache → fallback")
    }

    @MainActor
    func test_titleCache_ingestStream_laterTitleWins() {
        let tailer = SwrmEventTailer(projectRoot: tmpDir)
        let created = SwrmEventReader.read(fileURL: writeFile(
            line(seq: 1, type: "task.created", id: "3", title: "First") + "\n" +
            line(seq: 2, type: "task.created", id: "3", title: "Renamed") + "\n"))

        tailer.ingestTitles(from: created)

        XCTAssertEqual(tailer.resolvedTitle(forAggregateID: "3"), "Renamed",
                       "a later title-bearing event overwrites an earlier one")
    }

    // MARK: US-004 — "story started" trigger predicate (pure)

    /// Parse a single NDJSON line into a SwrmEvent via the reader (the only
    /// public constructor path) so predicate tests exercise real decoded data.
    private func event(type: String, id: String, to: String? = nil) -> SwrmEvent {
        let url = writeFile(line(seq: 1, type: type, id: id, to: to) + "\n")
        return SwrmEventReader.read(fileURL: url).first!
    }

    func test_trigger_taskMovedToInProgress_isStoryStarted() {
        XCTAssertTrue(event(type: "task.moved", id: "7", to: "in_progress").isStoryStarted)
    }

    func test_trigger_movedToOtherColumn_isNotStoryStarted() {
        XCTAssertFalse(event(type: "task.moved", id: "7", to: "done").isStoryStarted)
        XCTAssertFalse(event(type: "task.moved", id: "7", to: "todo").isStoryStarted)
    }

    func test_trigger_movedWithNoTo_isNotStoryStarted() {
        XCTAssertFalse(event(type: "task.moved", id: "7", to: nil).isStoryStarted)
    }

    func test_trigger_otherTypeToInProgress_isNotStoryStarted() {
        // Only task.moved trips the trigger — a created/completed event that
        // happened to carry to=in_progress must not.
        XCTAssertFalse(event(type: "task.created", id: "7", to: "in_progress").isStoryStarted)
        XCTAssertFalse(event(type: "task.completed", id: "7", to: "in_progress").isStoryStarted)
    }
}
