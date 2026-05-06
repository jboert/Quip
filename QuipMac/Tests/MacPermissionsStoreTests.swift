import XCTest
@testable import Quip

/// Pins the aggregation contract behind the menubar warning glyph (§22).
/// `deniedCount` lives on `MacPermissionsMessage`; `MacPermissionsStore`
/// forwards through it. Both layers tested so a future fourth TCC perm
/// addition can't silently regress the rollup.
@MainActor
final class MacPermissionsStoreTests: XCTestCase {

    // MARK: - MacPermissionsMessage.deniedCount

    func test_deniedCount_allGranted_isZero() {
        let m = MacPermissionsMessage(accessibility: true, appleEvents: true, screenRecording: true)
        XCTAssertEqual(m.deniedCount, 0)
    }

    func test_deniedCount_allDenied_isThree() {
        let m = MacPermissionsMessage(accessibility: false, appleEvents: false, screenRecording: false)
        XCTAssertEqual(m.deniedCount, 3)
    }

    func test_deniedCount_singleDenials() {
        XCTAssertEqual(MacPermissionsMessage(accessibility: false, appleEvents: true, screenRecording: true).deniedCount, 1)
        XCTAssertEqual(MacPermissionsMessage(accessibility: true, appleEvents: false, screenRecording: true).deniedCount, 1)
        XCTAssertEqual(MacPermissionsMessage(accessibility: true, appleEvents: true, screenRecording: false).deniedCount, 1)
    }

    func test_deniedCount_pairDenials() {
        XCTAssertEqual(MacPermissionsMessage(accessibility: false, appleEvents: false, screenRecording: true).deniedCount, 2)
        XCTAssertEqual(MacPermissionsMessage(accessibility: false, appleEvents: true, screenRecording: false).deniedCount, 2)
        XCTAssertEqual(MacPermissionsMessage(accessibility: true, appleEvents: false, screenRecording: false).deniedCount, 2)
    }

    // MARK: - MacPermissionsStore

    func test_store_nilSnapshot_reportsZeroAndFalse() {
        let store = MacPermissionsStore()
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.deniedCount, 0)
        XCTAssertFalse(store.anyDenied)
    }

    func test_store_allGrantedSnapshot_reportsZeroAndFalse() {
        let store = MacPermissionsStore()
        store.snapshot = MacPermissionsMessage(accessibility: true, appleEvents: true, screenRecording: true)
        XCTAssertEqual(store.deniedCount, 0)
        XCTAssertFalse(store.anyDenied)
    }

    func test_store_anyDenialFlipsAnyDenied() {
        let store = MacPermissionsStore()
        store.snapshot = MacPermissionsMessage(accessibility: false, appleEvents: true, screenRecording: true)
        XCTAssertEqual(store.deniedCount, 1)
        XCTAssertTrue(store.anyDenied)
    }

    func test_store_replaceSnapshot_updatesAggregate() {
        let store = MacPermissionsStore()
        store.snapshot = MacPermissionsMessage(accessibility: false, appleEvents: false, screenRecording: false)
        XCTAssertEqual(store.deniedCount, 3)
        XCTAssertTrue(store.anyDenied)

        store.snapshot = MacPermissionsMessage(accessibility: true, appleEvents: true, screenRecording: true)
        XCTAssertEqual(store.deniedCount, 0)
        XCTAssertFalse(store.anyDenied)
    }
}
