import XCTest
@testable import Quip

/// Locks the `BackendPickerSheet.classification(enabled:reachability:)` mapping
/// so every paired-backend row state shows the right caption + dot in the
/// picker. The bug being prevented: prior to GH G, every inactive paired
/// backend rendered grey regardless of its actual reachability — the user
/// couldn't tell which paired backends were currently live without flipping
/// to each one. (GH G.)
final class BackendPickerStatusTests: XCTestCase {

    func test_disabled_backend_classifiesOff_regardlessOfSessionState() {
        // Even if the session somehow has a stale reachability value, a
        // disabled-by-user backend shows Off.
        for r: BackendSession.Reachability? in [nil, .connecting, .connected, .unreachable, .needsAuth] {
            XCTAssertEqual(BackendPickerSheet.classification(enabled: false, reachability: r),
                           .off,
                           "enabled=false must always classify as .off (reachability=\(String(describing: r)))")
        }
    }

    func test_enabled_withoutSession_classifiesUnknown() {
        // Just-paired backend before bootstrap completes — there's no
        // session yet, so the row should render "Unknown" not "Connecting…".
        XCTAssertEqual(BackendPickerSheet.classification(enabled: true, reachability: nil),
                       .unknown)
    }

    func test_enabled_connecting_classifiesConnecting() {
        XCTAssertEqual(BackendPickerSheet.classification(enabled: true, reachability: .connecting),
                       .connecting)
    }

    func test_enabled_connected_classifiesConnected() {
        XCTAssertEqual(BackendPickerSheet.classification(enabled: true, reachability: .connected),
                       .connected)
    }

    func test_enabled_unreachable_classifiesUnreachable() {
        XCTAssertEqual(BackendPickerSheet.classification(enabled: true, reachability: .unreachable),
                       .unreachable)
    }

    func test_enabled_needsAuth_classifiesNeedsAuth() {
        XCTAssertEqual(BackendPickerSheet.classification(enabled: true, reachability: .needsAuth),
                       .needsAuth)
    }

    func test_captions_areAllNonEmpty() {
        // Avoid a future case where someone adds a state but forgets the
        // user-visible string.
        for c in BackendPickerSheet.RowStatus.allCases {
            XCTAssertFalse(c.caption.isEmpty,
                           "RowStatus.\(c.rawValue) caption is empty — picker would render a bare dot with no label")
        }
    }

    // MARK: - §J last-seen caption

    func test_lastSeen_connected_returnsNil() {
        // Showing "last seen 2m ago" next to "Connected" is confusing —
        // suppress the timestamp when the row is currently connected.
        XCTAssertNil(BackendPickerSheet.lastSeenCaption(status: .connected,
                                                         lastConnectedAt: Date(timeIntervalSinceNow: -120),
                                                         now: Date()))
    }

    func test_lastSeen_neverConnected_returnsNeverString() {
        XCTAssertEqual(BackendPickerSheet.lastSeenCaption(status: .unreachable,
                                                           lastConnectedAt: nil,
                                                           now: Date()),
                       "Never connected")
    }

    func test_lastSeen_recent_returnsMinutes() {
        let now = Date()
        let when = now.addingTimeInterval(-120) // 2 min ago
        XCTAssertEqual(BackendPickerSheet.lastSeenCaption(status: .unreachable,
                                                           lastConnectedAt: when,
                                                           now: now),
                       "Last seen 2m ago")
    }

    func test_lastSeen_hours() {
        let now = Date()
        let when = now.addingTimeInterval(-3 * 3600 - 60) // 3h+
        XCTAssertEqual(BackendPickerSheet.lastSeenCaption(status: .off,
                                                           lastConnectedAt: when,
                                                           now: now),
                       "Last seen 3h ago")
    }

    func test_lastSeen_days() {
        let now = Date()
        let when = now.addingTimeInterval(-5 * 86400) // 5d
        XCTAssertEqual(BackendPickerSheet.lastSeenCaption(status: .unreachable,
                                                           lastConnectedAt: when,
                                                           now: now),
                       "Last seen 5d ago")
    }

    func test_lastSeen_veryOld_flattensTo30dPlus() {
        let now = Date()
        let when = now.addingTimeInterval(-100 * 86400)
        XCTAssertEqual(BackendPickerSheet.lastSeenCaption(status: .unreachable,
                                                           lastConnectedAt: when,
                                                           now: now),
                       "Last seen 30d+ ago",
                       "Months/years would just be a wall clock — flatten to a single bucket")
    }

    func test_lastSeen_clockSkew_returnsJustNow() {
        // Future timestamps (clock skew) should display gracefully, not
        // as a negative duration.
        let now = Date()
        let when = now.addingTimeInterval(60) // 1 min in future
        XCTAssertEqual(BackendPickerSheet.lastSeenCaption(status: .unreachable,
                                                           lastConnectedAt: when,
                                                           now: now),
                       "Last seen just now")
    }

    func test_relativeAgo_belowOneMinute_collapsesToJustNow() {
        XCTAssertEqual(BackendPickerSheet.relativeAgo(seconds: 30), "just now")
    }
}
