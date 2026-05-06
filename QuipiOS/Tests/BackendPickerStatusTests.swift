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
}
