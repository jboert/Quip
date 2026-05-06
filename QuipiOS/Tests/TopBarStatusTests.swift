import XCTest
@testable import Quip

/// Locks `TopBarStatus.classify(...)` priority + lastError keyword
/// pattern matching so a future regression can't silently flip the
/// top bar back to "Connected" while the connection is actually
/// stalled, or surface "Connecting…" while a real auth failure is
/// going unread. (§K.)
final class TopBarStatusTests: XCTestCase {

    func test_connected_winsAlways() {
        // Even with stale isConnecting / lastError, a true isConnected
        // is the live signal — render Connected.
        XCTAssertEqual(TopBarStatus.classify(isConnected: true,
                                              isConnecting: true,
                                              isAuthenticated: true,
                                              lastError: "Stalled 26s",
                                              hasPaired: true),
                       .connected)
    }

    func test_noPaired_classifiesUnpaired() {
        XCTAssertEqual(TopBarStatus.classify(isConnected: false,
                                              isConnecting: false,
                                              isAuthenticated: false,
                                              lastError: nil,
                                              hasPaired: false),
                       .unpaired)
    }

    func test_authError_classifiesAuthFailed() {
        XCTAssertEqual(TopBarStatus.classify(isConnected: false,
                                              isConnecting: false,
                                              isAuthenticated: false,
                                              lastError: "Incorrect PIN",
                                              hasPaired: true),
                       .authFailed)
    }

    func test_pinKeyword_classifiesAuthFailed() {
        XCTAssertEqual(TopBarStatus.classify(isConnected: false,
                                              isConnecting: false,
                                              isAuthenticated: false,
                                              lastError: "PIN mismatch",
                                              hasPaired: true),
                       .authFailed)
    }

    func test_stalledError_classifiesStalled() {
        XCTAssertEqual(TopBarStatus.classify(isConnected: false,
                                              isConnecting: true,
                                              isAuthenticated: false,
                                              lastError: "Stalled 26s — resetting",
                                              hasPaired: true),
                       .stalled,
                       "A stalled-watchdog message must outrank the generic isConnecting → Connecting… path")
    }

    func test_noPongError_classifiesStalled() {
        XCTAssertEqual(TopBarStatus.classify(isConnected: false,
                                              isConnecting: true,
                                              isAuthenticated: false,
                                              lastError: "No pong (2/2)",
                                              hasPaired: true),
                       .stalled)
    }

    func test_timeoutError_classifiesStalled() {
        XCTAssertEqual(TopBarStatus.classify(isConnected: false,
                                              isConnecting: true,
                                              isAuthenticated: false,
                                              lastError: "Connection timed out",
                                              hasPaired: true),
                       .stalled)
    }

    func test_connecting_noError_classifiesConnecting() {
        XCTAssertEqual(TopBarStatus.classify(isConnected: false,
                                              isConnecting: true,
                                              isAuthenticated: false,
                                              lastError: nil,
                                              hasPaired: true),
                       .connecting)
    }

    func test_idle_paired_noError_classifiesStalled() {
        // "Not connecting, not connected, paired, no explicit error"
        // is the catch-all — usually a transient pause between a
        // forced disconnect and auto-reconnect. Showing "stalled"
        // beats showing nothing or a stale Connected.
        XCTAssertEqual(TopBarStatus.classify(isConnected: false,
                                              isConnecting: false,
                                              isAuthenticated: false,
                                              lastError: nil,
                                              hasPaired: true),
                       .stalled)
    }

    func test_allLabels_areNonEmpty() {
        for s in TopBarStatus.allCases {
            XCTAssertFalse(s.label.isEmpty,
                           "TopBarStatus.\(s.rawValue) label is empty — top bar would render an unlabeled dot")
        }
    }
}
