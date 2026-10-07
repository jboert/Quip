import XCTest
@testable import Quip

final class PhoneLogBufferTests: XCTestCase {
    func test_drainReturnsLinesInOrderAndEmpties() {
        var b = PhoneLogBuffer(capacity: 5)
        b.append("1"); b.append("2")
        XCTAssertEqual(b.drain(), ["1", "2"])
        XCTAssertEqual(b.drain(), [])
    }

    func test_offlineOverflowKeepsNewestAndSaysHowManyWereLost() {
        var b = PhoneLogBuffer(capacity: 3)
        for i in 1...5 { b.append("\(i)") }
        let out = b.drain()
        XCTAssertEqual(out.first, "[phone-log] dropped 2 older lines while offline")
        XCTAssertEqual(Array(out.dropFirst()), ["3", "4", "5"])
    }

    func test_requeueAfterFailedSendKeepsOrder() {
        var b = PhoneLogBuffer(capacity: 5)
        b.append("1"); b.append("2")
        let failed = b.drain()
        b.append("3")
        b.requeue(failed)
        XCTAssertEqual(b.drain(), ["1", "2", "3"])
    }
}
