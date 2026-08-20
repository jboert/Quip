import XCTest
@testable import Quip

/// `push.log` had reached 231 MB and `kokoro.log` 27.6 MB with no rotation
/// anywhere in LogPaths.
final class LogRotationTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quip-log-rotation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func test_rotateIfNeeded_leavesSmallFileAlone() throws {
        let path = dir.appendingPathComponent("small.log").path
        try String(repeating: "x", count: 100).write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertFalse(LogPaths.rotateIfNeeded(path: path, maxBytes: 1024))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".1"))
    }

    func test_rotateIfNeeded_movesOversizedFileToDotOne() throws {
        let path = dir.appendingPathComponent("big.log").path
        try String(repeating: "x", count: 5000).write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertTrue(LogPaths.rotateIfNeeded(path: path, maxBytes: 1024))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".1"))
    }

    /// Only one generation is kept — two rotations must not leave a .2 behind.
    func test_rotateIfNeeded_overwritesPreviousGeneration() throws {
        let path = dir.appendingPathComponent("big.log").path
        try String(repeating: "a", count: 5000).write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(LogPaths.rotateIfNeeded(path: path, maxBytes: 1024))

        try String(repeating: "b", count: 5000).write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(LogPaths.rotateIfNeeded(path: path, maxBytes: 1024))

        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".2"))
        let rolled = try String(contentsOfFile: path + ".1", encoding: .utf8)
        XCTAssertEqual(rolled.first, "b", "the newer generation should have replaced the older")
    }

    func test_rotateIfNeeded_missingFileIsNotAnError() {
        let path = dir.appendingPathComponent("absent.log").path
        XCTAssertFalse(LogPaths.rotateIfNeeded(path: path, maxBytes: 1024))
    }
}
