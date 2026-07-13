import XCTest
@testable import Quip

/// An audit log that silently stops auditing is worse than no audit log: it
/// still LOOKS like a record of what happened, so nobody goes looking for the
/// gap. `AuditLogger.log` used to drop its entry on any file-handle failure
/// with `guard ... else { return }` — no trace, anywhere.
///
/// The write path is a private static on a background queue, so what is testable
/// (and what actually broke) is the gating contract around it: a persistent
/// failure must report ONCE, not once per remote command, and it must key on
/// something that compares equal across identical failures.
final class AuditLoggerFailureReportingTests: XCTestCase {

    /// The audit path runs per remote message. A disk-full or permissions fault
    /// fails EVERY one of them, so an ungated line would flood the log it is
    /// trying to warn you in.
    func test_persistentWriteFailure_reportsOnceNotPerMessage() {
        let gate = LogTransitionGate<String>()
        var reports = 0
        for _ in 0..<200 where gate.evaluate("write", cause: "NSCocoaErrorDomain 640") == .report {
            reports += 1
        }
        XCTAssertEqual(reports, 1, "a persistent audit-write failure must report once, then stay quiet")
    }

    /// ...and recovery must be announced, so a reader knows the gap ended.
    func test_recovery_isAnnouncedOnce() {
        let gate = LogTransitionGate<String>()
        XCTAssertEqual(gate.evaluate("write", cause: "NSCocoaErrorDomain 640"), .report)
        XCTAssertEqual(gate.evaluate("write", cause: nil), .reportRecovery)
        XCTAssertEqual(gate.evaluate("write", cause: nil), .stayQuiet,
                       "a healthy audit log must not narrate its own health")
    }

    /// The trap: keying on an interpolated Cocoa NSError never suppresses,
    /// because userInfo's dictionary order is not stable. AuditLogger keys on
    /// domain+code precisely to avoid this.
    func test_keyingOnErrorShape_suppresses_whereInterpolationWouldNot() {
        func cocoaError() -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: 640, userInfo: [
                NSFilePathErrorKey: "/tmp/audit.log", "a": 1, "b": "two", "c": [1, 2], "d": ["k": "v"],
            ])
        }
        let shaped = LogTransitionGate<String>()
        var shapedReports = 0
        for _ in 0..<50 {
            let ns = cocoaError()
            if shaped.evaluate("write", cause: "\(ns.domain) \(ns.code)") == .report { shapedReports += 1 }
        }
        XCTAssertEqual(shapedReports, 1, "domain+code is stable — the gate must hold")

        let interpolated = LogTransitionGate<String>()
        var interpolatedReports = 0
        for _ in 0..<50 where interpolated.evaluate("write", cause: "\(cocoaError())") == .report {
            interpolatedReports += 1
        }
        XCTAssertGreaterThan(interpolatedReports, 1,
                             "interpolating an NSError defeats the gate — this is why AuditLogger must not")
    }
}
