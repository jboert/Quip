import XCTest
@testable import Quip

final class MessageDedupeTableTests: XCTestCase {

    func test_firstArrivalReturnsFalse_secondReturnsTrue() {
        let table = MessageDedupeTable()
        let id = UUID()
        XCTAssertFalse(table.checkAndRecord(id), "first arrival must be processed")
        XCTAssertTrue(table.checkAndRecord(id), "second arrival of same id must be deduped")
    }

    func test_distinctIds_areAllProcessed() {
        let table = MessageDedupeTable()
        for _ in 0..<10 {
            XCTAssertFalse(table.checkAndRecord(UUID()))
        }
    }

    func test_nilId_alwaysProcessed() {
        // Backwards-compat: older clients that don't send messageId must
        // still have their actions executed every time.
        let table = MessageDedupeTable()
        XCTAssertFalse(table.checkAndRecord(nil))
        XCTAssertFalse(table.checkAndRecord(nil))
        XCTAssertFalse(table.checkAndRecord(nil))
    }

    func test_capacityEvictsOldest() {
        let table = MessageDedupeTable(capacity: 3, ttl: 30)
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        XCTAssertFalse(table.checkAndRecord(a))
        XCTAssertFalse(table.checkAndRecord(b))
        XCTAssertFalse(table.checkAndRecord(c))
        XCTAssertEqual(table.count, 3)
        // Adding `d` evicts `a` (oldest).
        XCTAssertFalse(table.checkAndRecord(d))
        XCTAssertEqual(table.count, 3)
        // `b`, `c`, `d` still dedupe (assert BEFORE re-inserting `a`,
        // which would itself evict the next-oldest entry).
        XCTAssertTrue(table.checkAndRecord(b))
        XCTAssertTrue(table.checkAndRecord(c))
        XCTAssertTrue(table.checkAndRecord(d))
        // `a` was evicted earlier — its retry should now slip through.
        XCTAssertFalse(table.checkAndRecord(a),
                       "evicted id should no longer dedupe")
    }

    func test_ttlExpiresOldEntries() {
        var fakeNow = Date()
        let table = MessageDedupeTable(capacity: 100,
                                        ttl: 30,
                                        clock: { fakeNow })
        let id = UUID()
        XCTAssertFalse(table.checkAndRecord(id))
        XCTAssertTrue(table.checkAndRecord(id), "before TTL: still deduped")

        // Advance past TTL.
        fakeNow = fakeNow.addingTimeInterval(31)

        // The next check forces purgeExpired; the id rolls off.
        XCTAssertFalse(table.checkAndRecord(id),
                       "after TTL elapsed, id should be re-processable")
    }

    func test_ttlPurgePreservesFreshAndDropsStale() {
        var fakeNow = Date()
        let table = MessageDedupeTable(capacity: 100,
                                        ttl: 30,
                                        clock: { fakeNow })
        let stale = UUID()
        XCTAssertFalse(table.checkAndRecord(stale))
        // 25s later — stale is still within TTL, fresh just inserted.
        fakeNow = fakeNow.addingTimeInterval(25)
        let fresh = UUID()
        XCTAssertFalse(table.checkAndRecord(fresh))
        // Another 10s — stale now past 35s (>30 TTL), fresh at 10s.
        fakeNow = fakeNow.addingTimeInterval(10)
        // A third arrival triggers purge — stale rolls off, fresh stays.
        XCTAssertFalse(table.checkAndRecord(stale),
                       "stale id past TTL must be re-processable")
        XCTAssertTrue(table.checkAndRecord(fresh),
                      "fresh id within TTL must still dedupe")
    }

    func test_threadSafetyUnderConcurrentInsert() {
        // Hammer the table from many threads. Each thread writes 1000
        // distinct UUIDs; every write is a first arrival (returns
        // false). No data race ⇒ test passes; race ⇒ NSLock catches it
        // or we get inconsistent counts.
        let table = MessageDedupeTable(capacity: 100_000)
        let threadCount = 8
        let perThread = 1_000
        DispatchQueue.concurrentPerform(iterations: threadCount) { _ in
            for _ in 0..<perThread {
                _ = table.checkAndRecord(UUID())
            }
        }
        XCTAssertEqual(table.count, threadCount * perThread,
                       "all distinct UUIDs should land in the table without loss")
    }
}
