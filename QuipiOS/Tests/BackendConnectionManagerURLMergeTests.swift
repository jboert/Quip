import XCTest
@testable import Quip

/// Locks the URL-merge ordering contract shared by every BackendConnectionManager
/// merge path: `mergedURLOrder` (used by `mergeSameIDRows`/`mergeRows`) and, after
/// the consistency fix, `mergeNewURLInto`. Pure value-in/value-out — no networking.
///
/// Regression guard for the silent URL-order churn where re-pairing a known Mac
/// (LAN-first) disagreed with load/dedup (Tailscale-first).
@MainActor
final class BackendConnectionManagerURLMergeTests: XCTestCase {

    private let bonjour = "ws://quip-mac.local:8765"     // urlPriority 0
    private let lan     = "ws://192.168.4.26:8765"       // urlPriority 1
    private let ts      = "ws://100.120.141.122:8765"    // urlPriority 2 (Tailscale CGNAT)
    private let tsDNS   = "wss://mac.tail1234.ts.net"    // urlPriority 2 (Tailscale MagicDNS)
    private let other   = "wss://abc.trycloudflare.com"  // urlPriority 3

    // MARK: - urlPriority buckets

    func testURLPriorityBuckets() {
        XCTAssertEqual(BackendConnectionManager.urlPriority(bonjour), 0)
        XCTAssertEqual(BackendConnectionManager.urlPriority(lan), 1)
        XCTAssertEqual(BackendConnectionManager.urlPriority(ts), 2)
        XCTAssertEqual(BackendConnectionManager.urlPriority(tsDNS), 2)
        XCTAssertEqual(BackendConnectionManager.urlPriority(other), 3)
    }

    func testURLPriorityRFC1918Boundaries() {
        XCTAssertEqual(BackendConnectionManager.urlPriority("ws://10.0.0.5:8765"), 1)
        XCTAssertEqual(BackendConnectionManager.urlPriority("ws://172.16.0.1:8765"), 1)
        XCTAssertEqual(BackendConnectionManager.urlPriority("ws://172.31.255.1:8765"), 1)
        XCTAssertEqual(BackendConnectionManager.urlPriority("ws://172.32.0.1:8765"), 3) // just outside 16-31
        XCTAssertEqual(BackendConnectionManager.urlPriority("wss://relay.example.com:443"), 3) // parseable, non-RFC1918/Tailscale
        XCTAssertEqual(BackendConnectionManager.urlPriority("not a url"), 99) // unparseable → conservative last bucket
    }

    // MARK: - mergedURLOrder (Tailscale-first contract)

    func testMergedURLOrderTailscaleLeadsThenPriority() {
        let out = BackendConnectionManager.mergedURLOrder([lan, ts, bonjour, other])
        XCTAssertEqual(out, [ts, bonjour, lan, other],
                       "Tailscale leads; the rest keep Bonjour → LAN → other order")
    }

    func testMergedURLOrderTailscaleBeatsBonjour() {
        XCTAssertEqual(BackendConnectionManager.mergedURLOrder([bonjour, ts]), [ts, bonjour])
    }

    func testMergedURLOrderMagicDNSAlsoLeads() {
        XCTAssertEqual(BackendConnectionManager.mergedURLOrder([lan, tsDNS]), [tsDNS, lan])
    }

    func testMergedURLOrderNoTailscaleKeepsPriority() {
        XCTAssertEqual(BackendConnectionManager.mergedURLOrder([other, lan, bonjour]),
                       [bonjour, lan, other])
    }

    func testMergedURLOrderSingleURLUnchanged() {
        XCTAssertEqual(BackendConnectionManager.mergedURLOrder([lan]), [lan])
    }

    // MARK: - mergeSameIDRows (load/dedup path lands Tailscale-first)

    func testMergeSameIDRowsCollapsesSameIDTailscaleFirst() {
        let rows = [
            PairedBackend(id: "mac-1", url: lan, name: "Mac"),
            PairedBackend(id: "mac-1", url: ts,  name: "Mac"),
        ]
        let merged = BackendConnectionManager.mergeSameIDRows(rows)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].url, ts, "Merged primary is Tailscale-first")
        XCTAssertEqual(merged[0].urlsInOrder, [ts, lan])
    }

    func testMergeSameIDRowsFoldsURLOverlapAcrossIDs() {
        // Legacy synthetic id + real UUID for the same Mac (shared LAN url).
        let rows = [
            PairedBackend(id: "legacy",    url: lan, name: "Mac", fallbackURLs: [ts]),
            PairedBackend(id: "uuid-real", url: lan, name: "Mac"),
        ]
        let merged = BackendConnectionManager.mergeSameIDRows(rows)
        XCTAssertEqual(merged.count, 1, "Overlapping URL sets fold two ids into one row")
        XCTAssertEqual(merged[0].urlsInOrder.first, ts, "Folded row is still Tailscale-first")
    }

    func testMergeSameIDRowsEnabledIsOR() {
        let rows = [
            PairedBackend(id: "mac-1", url: lan, name: "Mac", enabled: false),
            PairedBackend(id: "mac-1", url: ts,  name: "Mac", enabled: true),
        ]
        let merged = BackendConnectionManager.mergeSameIDRows(rows)
        XCTAssertTrue(merged[0].enabled, "enabled is the OR of merged rows")
    }

    func testMergeSameIDRowsIdempotent() {
        let once = BackendConnectionManager.mergeSameIDRows([
            PairedBackend(id: "mac-1", url: lan, name: "Mac"),
            PairedBackend(id: "mac-1", url: ts,  name: "Mac"),
        ])
        let twice = BackendConnectionManager.mergeSameIDRows(once)
        XCTAssertEqual(once.map(\.urlsInOrder), twice.map(\.urlsInOrder))
    }

    func testMergeSameIDRowsEmptyIsSafe() {
        XCTAssertEqual(BackendConnectionManager.mergeSameIDRows([]).count, 0)
    }
}
