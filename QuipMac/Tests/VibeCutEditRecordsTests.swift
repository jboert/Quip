import XCTest
import CryptoKit
@testable import Quip

final class VibeCutEditRecordsTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("quip-editrecords-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        tmp = nil
        super.tearDown()
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func writeScript(_ id: String, _ bytes: String = "compiled") -> Data {
        let data = Data(bytes.utf8)
        try? data.write(to: tmp.appendingPathComponent(id + ".scpt"))
        return data
    }

    private func writeRecord(file: String, id: String, prompt: String = "EDITED",
                             mode: String = "send", type: String = "text", hash: String) {
        let json = """
        {"id":"\(id)","prompt":"\(prompt)","mode":"\(mode)","type":"\(type)",
         "skipPreamble":false,"screenshotPrefix":"\(id)","scriptSHA256":"\(hash)"}
        """
        try? json.write(to: tmp.appendingPathComponent(file + ".edit.json"),
                        atomically: true, encoding: .utf8)
    }

    private func catalog(_ id: String) -> VibeCutCatalog {
        VibeCutCatalog(prompts: [VibeCutPrompt(id: id, prompt: "CATALOG", mode: "paste", type: "text")])
    }

    func testValidRecordReplacesBodyAndMode() {
        let data = writeScript("a")
        writeRecord(file: "a", id: "a", mode: "send", type: "screenshot", hash: sha(data))
        let p = VibeCutEditRecords.apply(to: catalog("a"), actionsDirectory: tmp).prompts[0]
        XCTAssertEqual(p.prompt, "EDITED")
        XCTAssertEqual(p.mode, "send")
        XCTAssertEqual(p.type, "screenshot")
    }

    func testHashMismatchKeepsCatalog() {
        _ = writeScript("a")
        writeRecord(file: "a", id: "a", hash: String(repeating: "0", count: 64))
        XCTAssertEqual(VibeCutEditRecords.apply(to: catalog("a"), actionsDirectory: tmp), catalog("a"))
    }

    func testScriptOnlyWithoutRecordKeepsCatalog() {
        _ = writeScript("65-proceed")
        XCTAssertEqual(VibeCutEditRecords.apply(to: catalog("65-proceed"), actionsDirectory: tmp),
                       catalog("65-proceed"))
    }

    func testRecordIDMismatchKeepsCatalog() {
        let data = writeScript("a")
        writeRecord(file: "a", id: "b", hash: sha(data))
        XCTAssertEqual(VibeCutEditRecords.apply(to: catalog("a"), actionsDirectory: tmp), catalog("a"))
    }

    func testUnsafeIDNeverReadsOutsideDirectory() throws {
        // A valid-looking record one level above the actions dir, reachable only via "../x".
        let actions = tmp.appendingPathComponent("actions", isDirectory: true)
        try FileManager.default.createDirectory(at: actions, withIntermediateDirectories: true)
        let data = Data("compiled".utf8)
        try data.write(to: tmp.appendingPathComponent("x.scpt"))
        writeRecord(file: "x", id: "../x", hash: sha(data))
        XCTAssertFalse(VibeCutEditRecords.isSafeID("../x"))
        XCTAssertFalse(VibeCutEditRecords.isSafeID(".hidden"))
        XCTAssertFalse(VibeCutEditRecords.isSafeID("a/b"))
        XCTAssertFalse(VibeCutEditRecords.isSafeID(""))
        XCTAssertTrue(VibeCutEditRecords.isSafeID("65-proceed"))
        XCTAssertEqual(VibeCutEditRecords.apply(to: catalog("../x"), actionsDirectory: actions),
                       catalog("../x"))
    }

    func testBadModeKeepsCatalog() {
        let data = writeScript("a")
        writeRecord(file: "a", id: "a", mode: "yolo", hash: sha(data))
        XCTAssertEqual(VibeCutEditRecords.apply(to: catalog("a"), actionsDirectory: tmp), catalog("a"))
    }
}
