import XCTest
@testable import Quip

/// §30/4. Locks `WebSocketClient.decodeMessage` behavior:
/// - returns the decoded value on success without invoking the log sink
/// - returns nil on failure AND emits a single log line carrying the
///   message type tag, target Swift type, payload byte count, and
///   underlying decoder error
///
/// Format drift here is observable downstream — `~/Library/Logs/Quip/`
/// readers and the wishlist §B17 trace pipeline grep for the
/// `[WebSocketClient] decode FAILED` token. Renames or token reorders
/// will silently break that grep, hence the strict substring asserts.
final class DecodeMessageHelperTests: XCTestCase {

    private struct Payload: Codable, Equatable {
        let kind: String
        let n: Int
    }

    // MARK: - success path

    func testDecodeSuccessReturnsValueAndDoesNotLog() {
        let data = #"{"kind":"hi","n":7}"#.data(using: .utf8)!
        var logs: [String] = []
        let out = WebSocketClient.decodeMessage(
            Payload.self, from: data, msgType: "any") { logs.append($0) }
        XCTAssertEqual(out, Payload(kind: "hi", n: 7))
        XCTAssertTrue(logs.isEmpty, "Success path must not call log sink — got \(logs)")
    }

    // MARK: - failure path: malformed JSON

    func testDecodeMalformedJSONReturnsNilAndLogs() {
        let data = "{not json".data(using: .utf8)!
        var logs: [String] = []
        let out = WebSocketClient.decodeMessage(
            Payload.self, from: data, msgType: "broken") { logs.append($0) }
        XCTAssertNil(out)
        XCTAssertEqual(logs.count, 1, "Failure path must emit exactly one log line — got \(logs)")
        let line = logs[0]
        XCTAssertTrue(line.contains("[WebSocketClient] decode FAILED"),
                      "Missing canonical prefix in: \(line)")
        XCTAssertTrue(line.contains("type=broken"),
                      "Missing wire-type tag (msgType arg) in: \(line)")
        XCTAssertTrue(line.contains("kind=Payload"),
                      "Missing Swift target type in: \(line)")
        XCTAssertTrue(line.contains("bytes=\(data.count)"),
                      "Missing payload size in: \(line)")
        XCTAssertTrue(line.contains("err="),
                      "Missing underlying error in: \(line)")
    }

    // MARK: - failure path: schema drift (missing key)

    func testDecodeMissingRequiredKeyReturnsNilAndLogs() {
        let data = #"{"kind":"only"}"#.data(using: .utf8)!  // missing `n`
        var logs: [String] = []
        let out = WebSocketClient.decodeMessage(
            Payload.self, from: data, msgType: "drift") { logs.append($0) }
        XCTAssertNil(out)
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("type=drift"))
        XCTAssertTrue(logs[0].contains("kind=Payload"))
    }

    // MARK: - failure path: type mismatch

    func testDecodeWrongTypeReturnsNilAndLogs() {
        let data = #"{"kind":"hi","n":"not-an-int"}"#.data(using: .utf8)!
        var logs: [String] = []
        let out = WebSocketClient.decodeMessage(
            Payload.self, from: data, msgType: "wrongtype") { logs.append($0) }
        XCTAssertNil(out)
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("type=wrongtype"))
    }

    // MARK: - empty payload

    func testDecodeEmptyDataReturnsNilAndLogsZeroBytes() {
        let data = Data()
        var logs: [String] = []
        let out = WebSocketClient.decodeMessage(
            Payload.self, from: data, msgType: "empty") { logs.append($0) }
        XCTAssertNil(out)
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("bytes=0"),
                      "Zero-byte payload should report bytes=0 in: \(logs[0])")
    }

    // MARK: - msgType passthrough does not interpret payload

    func testMsgTypeIsOpaqueTagNotParsed() {
        let data = #"{"kind":"a","n":1}"#.data(using: .utf8)!
        var logs: [String] = []
        // Caller can pass any tag — even one that doesn't match the JSON.
        // Helper must not validate it; it's purely for log triage.
        let out = WebSocketClient.decodeMessage(
            Payload.self, from: data, msgType: "tag-need-not-match") { logs.append($0) }
        XCTAssertEqual(out?.kind, "a")
        XCTAssertTrue(logs.isEmpty)
    }
}
