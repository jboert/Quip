import XCTest
@testable import Quip

/// PRD broadcast-and-search US-111: whether each window got a broadcast, the
/// one-line result, and which windows a retry reselects.
final class BroadcastDeliveryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let names = ["web", "api", "db", "docs", "ops"]
    private let ids = (0..<5).map { _ in UUID() }

    /// A broadcast to the first `count` windows: "w0" named "web", "w1"
    /// named "api", and so on.
    private func broadcast(to count: Int, expectsAck: Bool = true) -> BroadcastDelivery {
        BroadcastDelivery(text: "run the tests", source: nil,
                          targets: (0..<count).map { (windowID: "w\($0)", name: names[$0], messageID: ids[$0]) },
                          expectsAck: expectsAck, startedAt: start)
    }

    private func deadline(plus seconds: TimeInterval = 0) -> Date {
        start.addingTimeInterval(BroadcastDelivery.deadline + seconds)
    }

    func test_everyAckMeansDeliveredToAll() {
        var delivery = broadcast(to: 3)
        XCTAssertFalse(delivery.isSettled)
        XCTAssertEqual(delivery.summary, "Broadcasting to 3…")
        for id in ids.prefix(3) { XCTAssertTrue(delivery.confirm(messageID: id)) }
        XCTAssertTrue(delivery.isSettled)
        XCTAssertEqual(delivery.summary, "Broadcast delivered to 3 of 3")
        XCTAssertEqual(delivery.retryWindowIDs, [])
    }

    func test_aTargetStillWaitingAtTheDeadlineIsUnconfirmedAndNamed() {
        var delivery = broadcast(to: 3)
        delivery.confirm(messageID: ids[0])
        delivery.confirm(messageID: ids[2])
        XCTAssertEqual(delivery.summary, "Broadcasting to 3…")
        XCTAssertTrue(delivery.expire(at: deadline()))
        XCTAssertEqual(delivery.targets.map(\.status), [.confirmed, .unconfirmed, .confirmed])
        XCTAssertTrue(delivery.isSettled)
        XCTAssertEqual(delivery.summary, "Broadcast: 2 of 3 confirmed — api did not answer")
        XCTAssertEqual(delivery.retryWindowIDs, ["w1"])
    }

    func test_expiringBeforeTheDeadlineChangesNothing() {
        var delivery = broadcast(to: 2)
        let before = delivery
        XCTAssertFalse(delivery.expire(at: deadline(plus: -0.001)))
        XCTAssertEqual(delivery, before)
        XCTAssertTrue(delivery.expire(at: deadline()), "the deadline itself counts")
        XCTAssertFalse(delivery.expire(at: deadline(plus: 60)), "nothing is left pending")
    }

    func test_acksForUnknownIdsAreIgnored() {
        var delivery = broadcast(to: 2)
        let before = delivery
        XCTAssertFalse(delivery.confirm(messageID: UUID()))
        XCTAssertFalse(delivery.fail(messageID: UUID()))
        XCTAssertEqual(delivery, before)
    }

    func test_aLateAckStillConfirms() {
        var delivery = broadcast(to: 2)
        delivery.confirm(messageID: ids[0])
        delivery.expire(at: deadline())
        XCTAssertTrue(delivery.confirm(messageID: ids[1]))
        XCTAssertEqual(delivery.summary, "Broadcast delivered to 2 of 2")
        XCTAssertEqual(delivery.retryWindowIDs, [])
    }

    func test_aConfirmedTargetStaysConfirmed() {
        var delivery = broadcast(to: 1)
        XCTAssertTrue(delivery.confirm(messageID: ids[0]))
        XCTAssertFalse(delivery.confirm(messageID: ids[0]))
        XCTAssertFalse(delivery.fail(messageID: ids[0]))
        XCTAssertEqual(delivery.targets.map(\.status), [.confirmed])
    }

    func test_pasteRouteTargetsCountAsSentWithoutAnAck() {
        var delivery = broadcast(to: 2, expectsAck: false)
        XCTAssertTrue(delivery.isSettled)
        XCTAssertEqual(delivery.targets.map(\.status), [.sent, .sent])
        XCTAssertEqual(delivery.summary, "Broadcast sent to 2")
        XCTAssertFalse(delivery.expire(at: deadline()), "nothing waits for a deadline")
        XCTAssertFalse(delivery.confirm(messageID: UUID()))
        XCTAssertEqual(delivery.summary, "Broadcast sent to 2")
        XCTAssertEqual(delivery.retryWindowIDs, [])
    }

    // MARK: - US-115: a Mac that acks paste_prompt settles sent targets too

    func test_aMacThatAcksPastesTurnsSentIntoDelivered() {
        var delivery = broadcast(to: 2, expectsAck: false)
        XCTAssertTrue(delivery.confirm(messageID: ids[0]))
        XCTAssertEqual(delivery.summary, "Broadcast sent to 2", "one ack is not every ack")
        XCTAssertTrue(delivery.confirm(messageID: ids[1]))
        XCTAssertEqual(delivery.summary, "Broadcast delivered to 2 of 2")
        XCTAssertFalse(delivery.confirm(messageID: ids[1]), "a repeat changes nothing")
    }

    func test_anAttributedErrorFailsASentTargetAndNamesIt() {
        var delivery = broadcast(to: 3, expectsAck: false)
        XCTAssertTrue(delivery.fail(messageID: ids[1]))
        XCTAssertEqual(delivery.targets.map(\.status), [.sent, .failed, .sent])
        XCTAssertEqual(delivery.retryWindowIDs, ["w1"])
        XCTAssertEqual(delivery.summary, "Broadcast: 2 of 3 sent — api failed")
        XCTAssertFalse(delivery.confirm(messageID: ids[1]), "an ack does not undo a failure")
        delivery.confirm(messageID: ids[0])
        delivery.confirm(messageID: ids[2])
        XCTAssertEqual(delivery.summary, "Broadcast: 2 of 3 sent — api failed",
                       "a mix of confirmed and failed on the no-ack route still reads as sent")
    }

    func test_anAttributedErrorOnTheAckRouteFailsBeforeTheDeadline() {
        var delivery = broadcast(to: 2)
        XCTAssertTrue(delivery.fail(messageID: ids[0]))
        XCTAssertTrue(delivery.confirm(messageID: ids[1]))
        XCTAssertTrue(delivery.isSettled, "no target waits for the deadline")
        XCTAssertEqual(delivery.summary, "Broadcast: 1 of 2 confirmed — web did not answer")
        XCTAssertEqual(delivery.retryWindowIDs, ["w0"])
    }

    func test_aFailedTargetIsOfferedForRetry() {
        var delivery = broadcast(to: 3)
        delivery.confirm(messageID: ids[0])
        XCTAssertTrue(delivery.fail(messageID: ids[1]))
        XCTAssertFalse(delivery.fail(messageID: ids[1]), "already failed")
        XCTAssertFalse(delivery.confirm(messageID: ids[1]), "an ack does not undo a failure")
        XCTAssertEqual(delivery.retryWindowIDs, ["w1"])
        XCTAssertEqual(delivery.summary, "Broadcasting to 3…")
        delivery.expire(at: deadline())
        XCTAssertEqual(delivery.targets.map(\.status), [.confirmed, .failed, .unconfirmed])
        XCTAssertEqual(delivery.retryWindowIDs, ["w1", "w2"])
        XCTAssertEqual(delivery.summary, "Broadcast: 1 of 3 confirmed — api, db did not answer")
    }

    func test_aTargetPastTheDeadlineCanStillFail() {
        var delivery = broadcast(to: 2)
        delivery.expire(at: deadline())
        XCTAssertTrue(delivery.fail(messageID: ids[1]))
        XCTAssertEqual(delivery.targets.map(\.status), [.unconfirmed, .failed])
        XCTAssertEqual(delivery.retryWindowIDs, ["w0", "w1"])
    }

    func test_pastTwoNamesTheSummaryCountsTheRest() {
        var five = broadcast(to: 5)
        five.confirm(messageID: ids[0])
        five.expire(at: deadline())
        XCTAssertEqual(five.summary, "Broadcast: 1 of 5 confirmed — api, db +2 more did not answer")

        var three = broadcast(to: 3)
        three.expire(at: deadline())
        XCTAssertEqual(three.summary, "Broadcast: 0 of 3 confirmed — web, api +1 more did not answer")
    }
}
