import XCTest
@testable import Quip

final class PhoneLogSinkTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func test_eachPhoneLineBecomesOneStampedRow() {
        let out = PhoneLogSink.format(["a", "b"], at: now)
        let rows = out.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(rows.count, 3, "two rows plus the trailing newline")
        XCTAssertTrue(rows[0].hasSuffix(" a"))
        XCTAssertTrue(rows[0].hasPrefix(now.ISO8601Format()))
        XCTAssertTrue(rows[1].hasSuffix(" b"))
    }

    func test_embeddedNewlinesCannotForgeRows() {
        let out = PhoneLogSink.format(["one\ntwo\rthree"], at: now)
        XCTAssertEqual(out.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(out.contains("one two three"))
    }

    func test_longLinesAndFloodsAreCapped() {
        let long = String(repeating: "x", count: PhoneLogSink.maxLineLength + 50)
        let row = PhoneLogSink.format([long], at: now)
        XCTAssertLessThan(row.count, PhoneLogSink.maxLineLength + 60)
        XCTAssertTrue(row.contains("…"))

        let flood = Array(repeating: "y", count: PhoneLogSink.maxLinesPerMessage + 10)
        let rows = PhoneLogSink.format(flood, at: now).filter { $0 == "\n" }.count
        XCTAssertEqual(rows, PhoneLogSink.maxLinesPerMessage)
    }

    func test_emptyMessageWritesNothing() {
        XCTAssertEqual(PhoneLogSink.format([], at: now), "")
    }
}
