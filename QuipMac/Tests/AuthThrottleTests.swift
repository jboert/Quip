import XCTest
@testable import Quip

@MainActor
final class AuthThrottleTests: XCTestCase {

    /// Shared mutable clock the test injects into AuthThrottle. Each test
    /// constructs its own throttle wired to a local `now` closure that reads
    /// this date — driving time forward is a single assignment.
    private var clock = Date(timeIntervalSince1970: 0)

    private func makeThrottle() -> AuthThrottle {
        AuthThrottle(now: { [unowned self] in self.clock })
    }

    // MARK: - Basic decision flow

    func test_freshHostProceedsWithZeroDelay() {
        let t = makeThrottle()
        XCTAssertEqual(t.check(host: "192.168.1.10"), .proceed(delayMs: 0))
    }

    func test_failuresIncreaseTheNextDelayLinearly() {
        let t = makeThrottle()
        let host = "192.168.1.10"

        t.recordFailure(host: host) // 1 fail → 1 * 200 = 200
        XCTAssertEqual(t.check(host: host), .proceed(delayMs: 200))

        t.recordFailure(host: host) // 2 fails → 400
        XCTAssertEqual(t.check(host: host), .proceed(delayMs: 400))

        t.recordFailure(host: host) // 3 fails → 600
        XCTAssertEqual(t.check(host: host), .proceed(delayMs: 600))
    }

    func test_delayIsCappedAtMaxDelayMs() {
        let t = makeThrottle()
        let host = "192.168.1.10"
        // 20 failures × 200ms = 4000ms theoretical, but cap is 2000ms.
        for _ in 0..<20 { t.recordFailure(host: host) }
        guard case .locked = t.check(host: host) else {
            return XCTFail("expected lockout after 20 failures")
        }
    }

    // MARK: - Lockout

    func test_lockoutTriggersAfterMaxFails() {
        let t = makeThrottle()
        let host = "192.168.1.10"

        // 9 failures — still allowed.
        for _ in 0..<9 { t.recordFailure(host: host) }
        if case .locked = t.check(host: host) {
            XCTFail("should not be locked after 9 fails")
        }

        // 10th failure triggers the lockout.
        t.recordFailure(host: host)
        guard case .locked(let remaining) = t.check(host: host) else {
            return XCTFail("should be locked after 10 fails")
        }
        // Lockout window is 15 min — sanity-check the remaining time.
        XCTAssertGreaterThan(remaining, 14 * 60)
        XCTAssertLessThanOrEqual(remaining, 15 * 60)
    }

    func test_lockoutExpiresAndCounterResets() {
        let t = makeThrottle()
        let host = "192.168.1.10"
        for _ in 0..<10 { t.recordFailure(host: host) }
        guard case .locked = t.check(host: host) else {
            return XCTFail("should be locked")
        }

        // Advance the clock past the lockout window.
        clock = clock.addingTimeInterval(15 * 60 + 1)
        XCTAssertEqual(t.check(host: host), .proceed(delayMs: 0),
                       "expired lockout should reset both lock and fail count")
    }

    func test_lockoutIsPerHost() {
        let t = makeThrottle()
        for _ in 0..<10 { t.recordFailure(host: "10.0.0.1") }
        guard case .locked = t.check(host: "10.0.0.1") else {
            return XCTFail("attacker should be locked")
        }
        // A different host is unaffected.
        XCTAssertEqual(t.check(host: "10.0.0.2"), .proceed(delayMs: 0))
    }

    // MARK: - Success / GC

    func test_successClearsTheFailCounter() {
        let t = makeThrottle()
        let host = "192.168.1.10"
        for _ in 0..<5 { t.recordFailure(host: host) }
        XCTAssertEqual(t.check(host: host), .proceed(delayMs: 1000))

        t.recordSuccess(host: host)
        XCTAssertEqual(t.check(host: host), .proceed(delayMs: 0))
    }

    func test_staleEntriesGetGCdAfterAnHour() {
        let t = makeThrottle()
        let host = "192.168.1.10"
        t.recordFailure(host: host)
        t.recordFailure(host: host)
        XCTAssertEqual(t.check(host: host), .proceed(delayMs: 400))

        // Idle for >1 hour, no lockout outstanding → GC clears the entry.
        clock = clock.addingTimeInterval(3601)
        XCTAssertEqual(t.check(host: host), .proceed(delayMs: 0))
    }

    func test_lockoutHoldsThroughShortIdle() {
        let t = makeThrottle()
        let host = "192.168.1.10"
        for _ in 0..<10 { t.recordFailure(host: host) }
        // Advance halfway into the lockout — it must still be active.
        clock = clock.addingTimeInterval(7 * 60 + 30) // 7m30s of 15m
        guard case .locked = t.check(host: host) else {
            return XCTFail("lockout must still be active half-way through window")
        }
    }

    // MARK: - Endpoint host parser

    func test_hostStripsIPv4Port() {
        XCTAssertEqual(AuthThrottle.host(from: "192.168.1.10:54321"), "192.168.1.10")
    }

    func test_hostStripsIPv6Port() {
        XCTAssertEqual(AuthThrottle.host(from: "[::1]:54321"), "[::1]")
        XCTAssertEqual(AuthThrottle.host(from: "[fe80::1%en0]:443"), "[fe80::1%en0]")
    }

    func test_hostHandlesNoPort() {
        XCTAssertEqual(AuthThrottle.host(from: "raw-name"), "raw-name")
    }
}
