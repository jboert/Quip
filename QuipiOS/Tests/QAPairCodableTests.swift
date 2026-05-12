import XCTest
@testable import Quip

final class QAPairCodableTests: XCTestCase {

    func testRoundTrip() {
        let pair = QAPair(targetId: "sim.42", terminalId: "iterm.117")
        let data = try! JSONEncoder().encode(pair)
        let decoded = try! JSONDecoder().decode(QAPair.self, from: data)
        XCTAssertEqual(decoded.targetId, "sim.42")
        XCTAssertEqual(decoded.terminalId, "iterm.117")
    }

    func testEquatable() {
        let a = QAPair(targetId: "1", terminalId: "2")
        let b = QAPair(targetId: "1", terminalId: "2")
        let c = QAPair(targetId: "1", terminalId: "3")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
