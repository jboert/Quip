import XCTest
@testable import Quip

final class QuipLogTests: XCTestCase {

    func test_line_tagsSeverityAndSubsystem() {
        let line = QuipLog.line(severity: .error, subsystem: "ws", message: "socket died")
        XCTAssertTrue(line.contains("[ERROR]"), "severity must be greppable: \(line)")
        XCTAssertTrue(line.contains("[ws]"), "subsystem must be greppable: \(line)")
        XCTAssertTrue(line.contains("socket died"))
        XCTAssertTrue(line.hasSuffix("\n"), "log lines must be newline-terminated")
    }

    func test_line_infoAndWarnAreDistinguishable() {
        let info = QuipLog.line(severity: .info, subsystem: "ws", message: "probe closed")
        let warn = QuipLog.line(severity: .warn, subsystem: "ws", message: "retrying")
        XCTAssertTrue(info.contains("[INFO]"))
        XCTAssertTrue(warn.contains("[WARN]"))
        XCTAssertFalse(info.contains("[ERROR]"), "a benign event must never read as an error")
    }

    func test_write_appendsAndCreatesFile() throws {
        let tmp = NSTemporaryDirectory() + "quiplog-test-\(UUID().uuidString).log"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        QuipLog.write(severity: .info, subsystem: "test", message: "first", to: tmp)
        QuipLog.write(severity: .error, subsystem: "test", message: "second", to: tmp)
        let contents = try String(contentsOfFile: tmp, encoding: .utf8)
        XCTAssertTrue(contents.contains("first"))
        XCTAssertTrue(contents.contains("second"))
        XCTAssertEqual(contents.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 2)
    }
}
