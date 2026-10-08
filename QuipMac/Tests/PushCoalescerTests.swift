import XCTest
@testable import Quip

/// Q-56: fewer, bundled pushes. Each rule against the shapes push.log showed.
final class PushCoalescerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func wait(_ id: String, fp: String? = "fp") -> PushCoalescer.Wait {
        PushCoalescer.Wait(windowId: id, windowName: id, projectName: nil, options: nil,
                           isYesNo: false, promptFingerprint: fp, promptPreview: nil)
    }

    func test_aBlipShorterThanDwellNeverPushes() {
        var c = PushCoalescer()
        c.waiting(wait("a"), at: t0)
        c.leftWaiting("a", at: t0.addingTimeInterval(4))
        XCTAssertNil(c.nextDeadline())
        XCTAssertEqual(c.due(at: t0.addingTimeInterval(60)), [])
    }

    func test_aRealWaitPushesAfterDwellPlusCoalesce() {
        var c = PushCoalescer()
        c.waiting(wait("a"), at: t0)
        XCTAssertEqual(c.nextDeadline(), t0.addingTimeInterval(18))
        XCTAssertEqual(c.due(at: t0.addingTimeInterval(17)), [])
        XCTAssertEqual(c.due(at: t0.addingTimeInterval(18)).map(\.windowId), ["a"])
        XCTAssertEqual(c.due(at: t0.addingTimeInterval(60)), [], "pushed once")
    }

    func test_siblingsRideInOnePush() {
        var c = PushCoalescer()
        c.waiting(wait("a"), at: t0)
        c.waiting(wait("b"), at: t0.addingTimeInterval(5))
        c.waiting(wait("c"), at: t0.addingTimeInterval(12), )
        let due = c.due(at: t0.addingTimeInterval(18))
        XCTAssertEqual(due.map(\.windowId), ["a", "b"], "c has not waited dwell yet")
        XCTAssertEqual(c.due(at: t0.addingTimeInterval(30)).map(\.windowId), ["c"])
    }

    func test_samePromptAfterABlipDoesNotPushAgain() {
        var c = PushCoalescer()
        c.waiting(wait("a"), at: t0)
        XCTAssertEqual(c.due(at: t0.addingTimeInterval(18)).count, 1)
        c.leftWaiting("a", at: t0.addingTimeInterval(40))
        XCTAssertFalse(c.waiting(wait("a"), at: t0.addingTimeInterval(45)), "same fingerprint, 5 s of work")
        XCTAssertNil(c.nextDeadline())
    }

    func test_aNewPromptPushesAgain() {
        var c = PushCoalescer()
        c.waiting(wait("a", fp: "one"), at: t0)
        _ = c.due(at: t0.addingTimeInterval(18))
        c.leftWaiting("a", at: t0.addingTimeInterval(40))
        XCTAssertTrue(c.waiting(wait("a", fp: "two"), at: t0.addingTimeInterval(45)))
        XCTAssertEqual(c.due(at: t0.addingTimeInterval(63)).map(\.promptFingerprint), ["two"])
    }

    func test_samePromptAfterRealWorkPushesAgain() {
        var c = PushCoalescer()
        c.waiting(wait("a"), at: t0)
        _ = c.due(at: t0.addingTimeInterval(18))
        c.leftWaiting("a", at: t0.addingTimeInterval(40))
        XCTAssertTrue(c.waiting(wait("a"), at: t0.addingTimeInterval(40 + 31)), "31 s of work: a new turn")
    }

    func test_unfingerprintedPromptsFollowTheSameRule() {
        var c = PushCoalescer()
        c.waiting(wait("a", fp: nil), at: t0)
        _ = c.due(at: t0.addingTimeInterval(18))
        c.leftWaiting("a", at: t0.addingTimeInterval(20))
        XCTAssertFalse(c.waiting(wait("a", fp: nil), at: t0.addingTimeInterval(25)))
        XCTAssertTrue(c.waiting(wait("a", fp: nil), at: t0.addingTimeInterval(20 + 31)))
    }

    func test_fresherDetailsReplaceThePendingOnesWithoutResettingDwell() {
        var c = PushCoalescer()
        c.waiting(wait("a", fp: nil), at: t0)
        c.waiting(wait("a", fp: "scraped"), at: t0.addingTimeInterval(1))
        XCTAssertEqual(c.nextDeadline(), t0.addingTimeInterval(18))
        XCTAssertEqual(c.due(at: t0.addingTimeInterval(18)).map(\.promptFingerprint), ["scraped"])
    }

    func test_forgetDropsEverythingForAWindow() {
        var c = PushCoalescer()
        c.waiting(wait("a"), at: t0)
        c.forget("a")
        XCTAssertNil(c.nextDeadline())
    }
}
