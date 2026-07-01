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

    // MARK: - determinism + dedup (review follow-ups)

    func testMergedURLOrderTwoTailscaleDeterministic() {
        // CGNAT + MagicDNS are both priority 2; the tiebreaker must make the
        // order independent of input order (no nondeterministic primary).
        XCTAssertEqual(BackendConnectionManager.mergedURLOrder([tsDNS, ts]),
                       BackendConnectionManager.mergedURLOrder([ts, tsDNS]))
    }

    func testMergeSameIDRowsDeduplicatesExactURLs() {
        let rows = [
            PairedBackend(id: "mac-1", url: ts, name: "Mac", fallbackURLs: [lan]),
            PairedBackend(id: "mac-1", url: ts, name: "Mac"),   // ts appears in both
        ]
        let merged = BackendConnectionManager.mergeSameIDRows(rows)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].urlsInOrder.filter { $0 == ts }.count, 1, "No duplicate URLs after merge")
        XCTAssertEqual(merged[0].urlsInOrder, [ts, lan])
    }

    func testMergeSameIDRowsSingleRowNotReordered() {
        // A lone row is passed through untouched — single-path backends keep
        // their persisted order (nothing to merge).
        let row = PairedBackend(id: "mac-1", url: lan, name: "Mac", fallbackURLs: [ts])
        let merged = BackendConnectionManager.mergeSameIDRows([row])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].urlsInOrder, [lan, ts])
    }

    // MARK: - LAN classification (Use Local Network switch)

    func testIsLANURL() {
        XCTAssertTrue(BackendConnectionManager.isLANURL(URL(string: bonjour)!), "Bonjour .local is LAN")
        XCTAssertTrue(BackendConnectionManager.isLANURL(URL(string: lan)!), "RFC1918 is LAN")
        XCTAssertFalse(BackendConnectionManager.isLANURL(URL(string: ts)!), "Tailscale CGNAT is not LAN")
        XCTAssertFalse(BackendConnectionManager.isLANURL(URL(string: tsDNS)!), "Tailscale MagicDNS is not LAN")
        XCTAssertFalse(BackendConnectionManager.isLANURL(URL(string: other)!), "Cloudflare tunnel is not LAN")
    }

    func testPathLabel() {
        XCTAssertEqual(BackendConnectionManager.pathLabel(for: URL(string: bonjour)!), "Local network")
        XCTAssertEqual(BackendConnectionManager.pathLabel(for: URL(string: lan)!), "Local network")
        XCTAssertEqual(BackendConnectionManager.pathLabel(for: URL(string: ts)!), "Tailscale")
        XCTAssertEqual(BackendConnectionManager.pathLabel(for: URL(string: tsDNS)!), "Tailscale")
        XCTAssertEqual(BackendConnectionManager.pathLabel(for: URL(string: other)!), "Remote")
        XCTAssertEqual(BackendConnectionManager.pathLabel(for: nil), "—")
    }

    // MARK: - urlsByAddingLocal (LAN URL ingestion from device_identity)

    func testAddingLocalURLLandsAsFallbackKeepingTailscalePrimary() {
        // Phone paired only over Tailscale; Mac's identity now reports its LAN
        // URL. LAN must join as a *fallback* — the live Tailscale primary is
        // never disrupted, but a LAN switch is now possible.
        let out = BackendConnectionManager.urlsByAddingLocal([ts], [lan])
        XCTAssertEqual(out, [ts, lan])
    }

    func testAddingLocalURLDeduplicates() {
        let out = BackendConnectionManager.urlsByAddingLocal([ts, lan], [lan])
        XCTAssertEqual(out, [ts, lan], "Already-known LAN URL is not duplicated")
    }

    func testAddingEmptyLocalURLsLeavesOrderUnchanged() {
        XCTAssertEqual(BackendConnectionManager.urlsByAddingLocal([ts, lan], []), [ts, lan])
    }

    func testAddingMultipleLocalURLs() {
        let out = BackendConnectionManager.urlsByAddingLocal([ts], [bonjour, lan])
        XCTAssertEqual(out, [ts, bonjour, lan], "TS stays primary; new LAN URLs sort Bonjour→LAN behind it")
    }

    // MARK: - consolidateByMonitorName (dual-backend flap one-shot)

    func testConsolidateByMonitorNameFoldsDisjointURLsSameName() {
        let rows = [
            PairedBackend(id: "legacy-x", url: lan, name: "Mac", lastSeenLayoutMonitorName: "Studio Display"),
            PairedBackend(id: "UUID-A",   url: ts,  name: "Mac", lastSeenLayoutMonitorName: "Studio Display"),
        ]
        let out = BackendConnectionManager.consolidateByMonitorName(rows)
        XCTAssertEqual(out.count, 1, "Same-Mac rows fold even with disjoint URLs + different ids")
        XCTAssertEqual(out[0].id, "UUID-A", "Real-UUID row survives, not the legacy one")
        XCTAssertEqual(out[0].urlsInOrder, [ts, lan], "URLs unioned Tailscale-first")
    }

    func testConsolidateByMonitorNameKeepsNilName() {
        let rows = [
            PairedBackend(id: "a", url: lan, name: "Mac", lastSeenLayoutMonitorName: "Studio Display"),
            PairedBackend(id: "b", url: ts,  name: "Mac", lastSeenLayoutMonitorName: nil),
        ]
        XCTAssertEqual(BackendConnectionManager.consolidateByMonitorName(rows).count, 2,
                       "nil monitor name is not evidence of sameness — never merge")
    }

    func testConsolidateByMonitorNameKeepsBothNil() {
        let rows = [
            PairedBackend(id: "a", url: lan, name: "Mac", lastSeenLayoutMonitorName: nil),
            PairedBackend(id: "b", url: ts,  name: "Mac", lastSeenLayoutMonitorName: nil),
        ]
        XCTAssertEqual(BackendConnectionManager.consolidateByMonitorName(rows).count, 2)
    }

    func testConsolidateByMonitorNameKeepsDifferentNames() {
        let rows = [
            PairedBackend(id: "a", url: lan, name: "Mac A", lastSeenLayoutMonitorName: "Studio Display"),
            PairedBackend(id: "b", url: ts,  name: "Mac B", lastSeenLayoutMonitorName: "LG UltraFine"),
        ]
        XCTAssertEqual(BackendConnectionManager.consolidateByMonitorName(rows).count, 2,
                       "Different monitor names = different Macs — never merge")
    }

    func testConsolidateByMonitorNameIdempotent() {
        let rows = [
            PairedBackend(id: "legacy-x", url: lan, name: "Mac", lastSeenLayoutMonitorName: "Studio Display"),
            PairedBackend(id: "UUID-A",   url: ts,  name: "Mac", lastSeenLayoutMonitorName: "Studio Display"),
        ]
        let once = BackendConnectionManager.consolidateByMonitorName(rows)
        let twice = BackendConnectionManager.consolidateByMonitorName(once)
        XCTAssertEqual(once.map(\.urlsInOrder), twice.map(\.urlsInOrder))
        XCTAssertEqual(twice.count, 1)
    }
}
