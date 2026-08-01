import XCTest
@testable import Quip

/// `checkLogForURL` used to slurp and split the entire cloudflared log on the
/// main thread once per second, forever, against a file that keeps growing.
/// These pin the incremental reader that replaced it.
final class TunnelLogTailTests: XCTestCase {

    private var path: String!

    override func setUpWithError() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quip-tunnel-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("tunnel.log").path
    }

    override func tearDownWithError() throws {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ contents: String) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func test_readsCompleteLinesAndAdvancesOffset() throws {
        try write("alpha\nbeta\n")

        let (lines, next) = CloudflareTunnel.readLogTail(path: path, from: 0)

        XCTAssertEqual(lines, "alpha\nbeta\n")
        XCTAssertEqual(next, 11)
    }

    /// The whole point: a second pass reads only what was appended.
    func test_secondPassReadsOnlyTheAppendedTail() throws {
        try write("alpha\n")
        let (_, first) = CloudflareTunnel.readLogTail(path: path, from: 0)

        try write("alpha\nbeta\n")
        let (lines, next) = CloudflareTunnel.readLogTail(path: path, from: first)

        XCTAssertEqual(lines, "beta\n")
        XCTAssertEqual(next, 11)
    }

    /// A trailing partial line must be left for the next tick, not parsed
    /// half-written — cloudflared is appending while we read.
    func test_partialTrailingLineIsNotConsumed() throws {
        try write("alpha\npar")

        let (lines, next) = CloudflareTunnel.readLogTail(path: path, from: 0)

        XCTAssertEqual(lines, "alpha\n")
        XCTAssertEqual(next, 6, "cursor must stop at the last newline")
    }

    func test_noNewBytes_returnsEmptyAndHoldsOffset() throws {
        try write("alpha\n")
        let (_, first) = CloudflareTunnel.readLogTail(path: path, from: 0)

        let (lines, next) = CloudflareTunnel.readLogTail(path: path, from: first)

        XCTAssertEqual(lines, "")
        XCTAssertEqual(next, first)
    }

    /// cloudflared truncates the log on restart; a stale cursor past EOF must
    /// rewind rather than read garbage or skip the new URL line.
    func test_truncatedFile_rewindsCursorToZero() throws {
        try write("a long first run\n")
        let (_, first) = CloudflareTunnel.readLogTail(path: path, from: 0)
        XCTAssertGreaterThan(first, 0)

        try write("x\n")
        let (lines, next) = CloudflareTunnel.readLogTail(path: path, from: first)

        XCTAssertEqual(lines, "")
        XCTAssertEqual(next, 0)
    }

    func test_missingFile_holdsOffset() {
        let absent = path + ".absent"
        let (lines, next) = CloudflareTunnel.readLogTail(path: absent, from: 42)
        XCTAssertEqual(lines, "")
        XCTAssertEqual(next, 42)
    }

    func test_firstTunnelURL_findsURLInJSONLogLine() {
        let lines = """
        {"level":"inf","message":"starting"}
        {"level":"inf","message":"https://calm-fox-1234.trycloudflare.com"}

        """
        XCTAssertEqual(
            CloudflareTunnel.firstTunnelURL(inLines: lines),
            "https://calm-fox-1234.trycloudflare.com"
        )
    }

    func test_firstTunnelURL_returnsNilWhenAbsent() {
        XCTAssertNil(CloudflareTunnel.firstTunnelURL(inLines: "nothing here\nor here\n"))
    }
}
