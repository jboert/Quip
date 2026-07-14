import XCTest
@testable import Quip

/// The guard's contract, exercised against real files in a temp dir.
///
/// These are in-process claims on distinct file descriptors. BSD flock scopes a
/// lock to the open file description, not the process, so a second `open` +
/// `flock` from THIS process collides exactly the way a second Quip would —
/// which is what makes the duplicate-instance case testable without spawning an
/// app.
final class SingleInstanceGuardTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quip-instance-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var lockURL: URL { dir.appendingPathComponent("instance.lock") }

    func testFirstClaimAcquires() {
        guard case .acquired(let lock) = SingleInstanceGuard.claim(at: lockURL) else {
            return XCTFail("first claim must acquire an unheld lock")
        }
        lock.release()
    }

    func testSecondClaimSeesTheFirstOneRunning() {
        guard case .acquired(let first) = SingleInstanceGuard.claim(at: lockURL) else {
            return XCTFail("first claim must acquire")
        }
        defer { first.release() }

        // This is the login-item-vs-launchd collision, in miniature.
        XCTAssertEqual(SingleInstanceGuard.claim(at: lockURL), .alreadyRunning)
    }

    func testReleasingLetsTheNextInstanceIn() {
        guard case .acquired(let first) = SingleInstanceGuard.claim(at: lockURL) else {
            return XCTFail("first claim must acquire")
        }
        first.release()

        // A crashed Quip has its lock dropped by the kernel; CrashRecoveryAgent's
        // relaunch must be able to claim the session rather than immediately
        // quitting itself.
        guard case .acquired(let second) = SingleInstanceGuard.claim(at: lockURL) else {
            return XCTFail("a released lock must be re-acquirable")
        }
        second.release()
    }

    func testClaimCreatesMissingParentDirectory() {
        let nested = dir.appendingPathComponent("a/b/c/instance.lock")
        guard case .acquired(let lock) = SingleInstanceGuard.claim(at: nested) else {
            return XCTFail("claim must create its own directory tree")
        }
        defer { lock.release() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    /// Fail open. A lock we cannot evaluate must never be reported as
    /// `.alreadyRunning`, because the caller quits on that — an unwritable
    /// lock path would otherwise make Quip permanently unlaunchable.
    func testUnusablePathIsUnavailableAndNotAlreadyRunning() {
        let unwritable = URL(fileURLWithPath: "/System/quip-guard-denied/instance.lock")
        let claim = SingleInstanceGuard.claim(at: unwritable)
        switch claim {
        case .unavailable:
            break
        case .acquired(let lock):
            lock.release()
            XCTFail("did not expect to be able to write inside /System")
        case .alreadyRunning:
            XCTFail("an unusable lock path must fail open, not report a running instance")
        }
    }
}

extension InstanceClaim: Equatable {
    public static func == (lhs: InstanceClaim, rhs: InstanceClaim) -> Bool {
        switch (lhs, rhs) {
        case (.alreadyRunning, .alreadyRunning): return true
        case (.acquired, .acquired): return true
        case (.unavailable(let l), .unavailable(let r)): return l == r
        default: return false
        }
    }
}
