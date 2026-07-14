// SingleInstanceGuard.swift
// QuipMac — makes a second copy of Quip refuse to run.
//
// Quip has TWO independent launchers and they do not know about each other:
//
//   1. the login item, which opens /Applications/Quip.app via LaunchServices
//   2. `CrashRecoveryAgent`'s LaunchAgent, whose ProgramArguments exec the raw
//      Mach-O at Contents/MacOS/Quip (RunAtLoad = true)
//
// LaunchServices dedupes launches of an app bundle — that is why double-clicking
// a running app just focuses it. launchd exec's the binary directly and so
// bypasses that check entirely: at login the user gets one Quip from each
// launcher. Two menu-bar icons, and two servers racing to bind port 8765.
//
// The dedupe therefore has to live in the app. The mechanism is an exclusive
// `flock` on a lock file, chosen over an NSRunningApplication scan for two
// reasons:
//
//   * It is atomic. Both instances start within milliseconds of each other at
//     login, so a "is anyone else running?" *check* followed by a *claim* is a
//     race both instances can win. flock claims and answers in one syscall.
//   * The kernel drops the lock when the holder dies — including on a crash,
//     which is exactly when CrashRecoveryAgent relaunches us. A lock file
//     holding a pid would need stale-entry reaping; this cannot go stale.
//
// Losing the race is not an error: the user gets the Quip that won, which is a
// perfectly good Quip. The loser exits 0 — deliberately, because the LaunchAgent
// carries `KeepAlive.SuccessfulExit = false`, so a zero exit tells launchd this
// was an orderly quit and NOT to relaunch us into a loop.

import Foundation

/// A held exclusive lock. Must be kept alive for as long as the instance runs:
/// the lock lives on the open file description, so releasing or deallocating
/// this token releases the lock and lets another Quip in.
final class InstanceLock {
    private let fd: Int32
    private let url: URL

    fileprivate init(fd: Int32, url: URL) {
        self.fd = fd
        self.url = url
    }

    /// Drop the lock. The file itself is left behind on purpose — an empty lock
    /// file is the normal resting state, and unlinking it would race a second
    /// instance that has already opened it (it would lock a now-orphaned inode
    /// and both instances would think they won).
    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

enum InstanceClaim {
    /// This process owns the session. Hold the token for the process lifetime.
    case acquired(InstanceLock)
    /// Another Quip already holds the lock.
    case alreadyRunning
    /// The lock could not be evaluated (unwritable directory, bad path…).
    /// Callers MUST fail open and start anyway: refusing to launch because we
    /// could not open a lock file would be a far worse bug than the duplicate
    /// instance this whole file exists to prevent.
    case unavailable(String)
}

enum SingleInstanceGuard {

    static var defaultLockURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Quip/instance.lock")
    }

    /// True when running inside the XCTest host. The Mac tests are app-hosted:
    /// `xcodebuild test` launches its own Quip.app to run them in. If a real Quip
    /// is already running, an unconditional guard would terminate the test host
    /// mid-suite. Skipping here keeps the guard honest in production while
    /// leaving the suite runnable.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
    }

    /// Claim the session, atomically. See the file header for why this is a
    /// single syscall rather than a check-then-act.
    static func claim(at url: URL) -> InstanceClaim {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            let ns = error as NSError
            return .unavailable("could not create \(dir.path) (\(ns.domain) \(ns.code))")
        }

        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            return .unavailable("could not open \(url.lastPathComponent) (errno \(errno))")
        }

        // LOCK_NB: answer now. Blocking here would hang launch behind the other
        // instance's entire lifetime.
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            return .acquired(InstanceLock(fd: fd, url: url))
        }

        let failure = errno
        close(fd)
        // EWOULDBLOCK is the whole point of the guard: someone else holds it.
        // Anything else means the lock is broken rather than taken, so fail open.
        if failure == EWOULDBLOCK {
            return .alreadyRunning
        }
        return .unavailable("could not lock \(url.lastPathComponent) (errno \(failure))")
    }
}
