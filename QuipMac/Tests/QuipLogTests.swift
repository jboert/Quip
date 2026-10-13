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

    /// A location whose parent directory doesn't exist: `FileHandle(forWritingAtPath:)`
    /// returns nil, and the fallback `FileManager.createFile` also fails silently.
    /// Covers the "nonexistent location" half of the swallow-failures contract.
    func test_write_toNonexistentDirectory_doesNotCrashOrThrow() {
        let path = NSTemporaryDirectory() + "quiplog-no-such-dir-\(UUID().uuidString)/quip.log"
        QuipLog.write(severity: .error, subsystem: "test", message: "should be swallowed", to: path)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: path),
            "the parent directory doesn't exist, so nothing should have been written"
        )
        // Reaching this line at all is the assertion: the legacy
        // `FileHandle.write(_:)`/`seekToEndOfFile()` API raises an
        // uncatchable NSException that would abort the whole process before
        // any XCTAssert below it ever ran.
    }

    /// The literal scenario `QuipLog`'s doc comment promises to survive: a
    /// write that fails partway through because the disk is full. This is
    /// the regression test for the CRITICAL finding — with the legacy
    /// `FileHandle.write(_:)` / `seekToEndOfFile()` APIs, a failed write on
    /// an already-open handle raises an Objective-C NSException that Swift's
    /// do/try/catch cannot intercept, which aborts the entire process
    /// (verified locally: `*** Terminating app due to uncaught exception
    /// 'NSFileHandleOperationException' ... No space left on device`).
    /// Simulated with a tiny HFS+ disk image filled to capacity so the
    /// write genuinely fails at the OS level rather than being mocked.
    func test_write_whenDiskIsFull_doesNotCrashOrThrow() throws {
        let fm = FileManager.default
        let workDir = NSTemporaryDirectory() + "quiplog-diskfull-\(UUID().uuidString)"
        let dmgPath = workDir + ".dmg"
        let mountPoint = workDir + "-mount"
        try fm.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)

        // hdiutil has hung here (2026-10-13: `create` stuck for 10 minutes
        // with the disk-image service wedged), so each call gets a deadline
        // and reports whether it finished cleanly.
        @discardableResult
        func run(_ tool: String, _ args: [String], timeout: TimeInterval = 30) throws -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if p.isRunning {
                p.terminate()
                return false
            }
            return p.terminationStatus == 0
        }

        defer {
            try? run("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet", "-force"])
            try? fm.removeItem(atPath: dmgPath)
            try? fm.removeItem(atPath: mountPoint)
        }
        guard try run("/usr/bin/hdiutil", ["create", "-size", "1m", "-fs", "HFS+", "-volname", "QuipLogTest", dmgPath]),
              try run("/usr/bin/hdiutil", ["attach", dmgPath, "-mountpoint", mountPoint, "-nobrowse", "-quiet"]) else {
            throw XCTSkip("hdiutil could not create or attach the 1 MB test image")
        }
        // Without the image mounted, mountPoint is a plain folder on the boot
        // volume and the fill below would fill the Mac's own disk: it wrote
        // 20 GB there on 2026-10-13 before it was stopped. Refuse to go on
        // unless mountPoint is its own volume.
        let mountVolume = try URL(fileURLWithPath: mountPoint).resourceValues(forKeys: [.volumeURLKey]).volume
        let tmpVolume = try URL(fileURLWithPath: NSTemporaryDirectory()).resourceValues(forKeys: [.volumeURLKey]).volume
        guard let mountVolume, mountVolume != tmpVolume else {
            throw XCTSkip("test image is not mounted at \(mountPoint)")
        }

        let logPath = mountPoint + "/quip.log"
        // Seed the file so `FileHandle(forWritingAtPath:)` opens an existing
        // (writable-at-open-time) handle — the code path that raises the
        // exception. A brand-new path would fall into the `createFile`
        // fallback instead, which never threw even before this fix.
        fm.createFile(atPath: logPath, contents: Data("seed\n".utf8))

        // Fill the volume to capacity.
        let fillerPath = mountPoint + "/filler.bin"
        fm.createFile(atPath: fillerPath, contents: nil)
        if let filler = FileHandle(forWritingAtPath: fillerPath) {
            // The image is 1 MB; the 4 MB cap is a second guard so a wrong
            // volume can never be filled.
            let chunk = Data(repeating: 0, count: 64 * 1024)
            var written = 0
            while written < 4 * 1024 * 1024, (try? filler.write(contentsOf: chunk)) != nil {
                written += chunk.count
            }
            try? filler.close()
        }

        // The volume is now full. This write must fail at the OS level but
        // must not crash the test process or throw out of this function.
        QuipLog.write(severity: .error, subsystem: "test", message: String(repeating: "x", count: 50_000), to: logPath)

        // Reaching this line is the proof: the old implementation aborts the
        // process before it ever gets here.
        XCTAssertTrue(true, "process survived a write to a full disk")
    }
}
