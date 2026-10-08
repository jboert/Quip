import XCTest
@testable import Quip

/// Locks the notification-answer queue (Q-57): an answer with no socket is
/// kept and persisted, goes out once a socket delivers, and is dropped once
/// the prompt is surely gone.
@MainActor
final class PushAnswerQueueTests: XCTestCase {
    private let key = "pushAnswerQueue.test"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    private func queue() -> PushAnswerQueue {
        let q = PushAnswerQueue(storageKey: key)
        q.notify = { _, _ in }
        return q
    }

    func test_noSocket_keepsAndPersists_andWakes() {
        let q = queue()
        var woke = 0
        q.deliver = { _ in false }
        q.wake = { woke += 1 }
        q.enqueue(PushAnswer(windowId: "w1", action: "press_y", promptFingerprint: "f"))
        XCTAssertEqual(q.pending.count, 1)
        XCTAssertEqual(woke, 1)
        let reloaded = PushAnswerQueue(storageKey: key)
        XCTAssertEqual(reloaded.pending.map(\.windowId), ["w1"], "survives a relaunch")
    }

    func test_socket_sendsInOrder_andClears() {
        let q = queue()
        var sent: [String] = []
        q.deliver = { _ in false }
        q.enqueue(PushAnswer(windowId: "a", action: "press_y", promptFingerprint: nil))
        q.enqueue(PushAnswer(windowId: "b", text: "use the cache", promptFingerprint: nil))
        q.deliver = { a in sent.append(a.summary); return true }
        q.flush()
        XCTAssertEqual(sent, ["press_y", "reply(13 chars)"])
        XCTAssertTrue(q.pending.isEmpty)
        XCTAssertNil(UserDefaults.standard.data(forKey: key), "nothing left to persist")
        XCTAssertNotNil(q.lastSentAt)
    }

    func test_stale_isDropped_notSent() {
        let q = queue()
        var sent = 0
        q.deliver = { _ in sent += 1; return true }
        let old = PushAnswer(windowId: "a", action: "select_2", promptFingerprint: nil,
                             createdAt: Date(timeIntervalSinceNow: -(PushAnswerQueue.maxAge + 1)))
        q.deliver = { _ in false }
        q.enqueue(old, now: old.createdAt)
        q.deliver = { _ in sent += 1; return true }
        q.flush()
        XCTAssertEqual(sent, 0)
        XCTAssertTrue(q.pending.isEmpty)
    }

    func test_promptChanged_noticeOnlyRightAfterASend_andOnlyInBackground() {
        let q = queue()
        var notices: [String] = []
        q.notify = { title, _ in notices.append(title) }
        q.deliver = { _ in true }
        q.enqueue(PushAnswer(windowId: "a", action: "press_y", promptFingerprint: "f"))
        q.promptChanged("Prompt changed — not sent", appIsActive: true)
        XCTAssertTrue(notices.isEmpty, "the in-app toast covers the foreground")
        q.promptChanged("Prompt changed — not sent", appIsActive: false)
        XCTAssertEqual(notices, ["Answer not sent"])
        q.promptChanged("Prompt changed — not sent", now: Date(timeIntervalSinceNow: 60), appIsActive: false)
        XCTAssertEqual(notices.count, 1, "an old send does not own a later error")
    }

    func test_pruned_isPure() {
        let now = Date()
        let fresh = PushAnswer(windowId: "a", action: "press_n", promptFingerprint: nil, createdAt: now)
        let stale = PushAnswer(windowId: "b", action: "press_n", promptFingerprint: nil,
                               createdAt: now.addingTimeInterval(-700))
        let r = PushAnswerQueue.pruned([fresh, stale], now: now)
        XCTAssertEqual(r.kept, [fresh])
        XCTAssertEqual(r.dropped, [stale])
    }
}
