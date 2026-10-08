import XCTest
@testable import Quip

/// PRD 2026-10-07, US-012 steps 1 and 6: which resolved address a Bonjour row
/// offers, how a later, better address replaces the row, and which discovered
/// Macs the connect bar lists.
@MainActor
final class BonjourAddressPickerTests: XCTestCase {

    // MARK: - pick

    func test_pick_prefersRoutableOverLinkLocal() {
        XCTAssertEqual(BonjourAddressPicker.pick(["169.254.1.2", "192.168.1.20"]), "192.168.1.20")
    }

    func test_pick_fallsBackToLinkLocalWhenNothingElseResolved() {
        XCTAssertEqual(BonjourAddressPicker.pick(["169.254.1.2"]), "169.254.1.2")
    }

    func test_pick_neverOffersLoopback() {
        XCTAssertEqual(BonjourAddressPicker.pick(["127.0.0.1", "169.254.1.2"]), "169.254.1.2")
        XCTAssertNil(BonjourAddressPicker.pick(["127.0.0.1"]))
        XCTAssertNil(BonjourAddressPicker.pick([]))
    }

    func test_pick_keepsTheResolverOrderAmongRoutableAddresses() {
        XCTAssertEqual(BonjourAddressPicker.pick(["10.0.0.5", "192.168.1.20"]), "10.0.0.5")
    }

    // MARK: - classification

    func test_linkLocalRange() {
        XCTAssertTrue(BonjourAddressPicker.isLinkLocalIPv4("169.254.1.2"))
        XCTAssertTrue(BonjourAddressPicker.isLinkLocalIPv4("169.254.0.0"))
        XCTAssertTrue(BonjourAddressPicker.isLinkLocalIPv4("169.254.255.255"))
        XCTAssertFalse(BonjourAddressPicker.isLinkLocalIPv4("169.253.1.2"), "just below 169.254/16")
        XCTAssertFalse(BonjourAddressPicker.isLinkLocalIPv4("169.255.1.2"), "just above 169.254/16")
        XCTAssertFalse(BonjourAddressPicker.isLinkLocalIPv4("192.168.1.20"))
        XCTAssertFalse(BonjourAddressPicker.isLinkLocalIPv4("127.0.0.1"))
        XCTAssertFalse(BonjourAddressPicker.isLinkLocalIPv4("100.100.1.1"), "Tailscale CGNAT")
    }

    func test_linkLocalUsesAStrictParse() {
        XCTAssertFalse(BonjourAddressPicker.isLinkLocalIPv4("169.254.1"))
        XCTAssertFalse(BonjourAddressPicker.isLinkLocalIPv4("169.254.1.2.3"))
        XCTAssertFalse(BonjourAddressPicker.isLinkLocalIPv4("169.254.1.256"))
        XCTAssertFalse(BonjourAddressPicker.isLinkLocalIPv4("169.254..2"))
        XCTAssertFalse(BonjourAddressPicker.isLinkLocalIPv4("quip-mac.local"))
        XCTAssertFalse(BonjourAddressPicker.isLinkLocalIPv4("fe80::1"), "IPv6 link-local is not IPv4")
        XCTAssertFalse(BonjourAddressPicker.isLinkLocalIPv4(""))
    }

    func test_linkLocalAndRFC1918AreDisjoint() {
        for ip in ["169.254.1.2", "169.254.200.9", "10.0.0.5", "172.16.0.1", "192.168.1.20"] {
            XCTAssertNotEqual(BonjourAddressPicker.isLinkLocalIPv4(ip), NetworkClassifier.isRFC1918IPv4(ip), ip)
        }
    }

    func test_loopback() {
        XCTAssertTrue(BonjourAddressPicker.isLoopbackIPv4("127.0.0.1"))
        XCTAssertTrue(BonjourAddressPicker.isLoopbackIPv4("127.8.9.10"))
        XCTAssertFalse(BonjourAddressPicker.isLoopbackIPv4("128.0.0.1"))
    }

    // MARK: - sockaddr parsing

    private func sockaddrIPv4(_ ip: String, port: UInt16 = 8765) -> Data {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        _ = inet_pton(AF_INET, ip, &addr.sin_addr)
        return withUnsafeBytes(of: &addr) { Data($0) }
    }

    private func sockaddrIPv6Loopback() -> Data {
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_addr = in6addr_loopback
        return withUnsafeBytes(of: &addr) { Data($0) }
    }

    func test_ipv4Strings_readsIPv4InOrderAndSkipsIPv6AndJunk() {
        let addresses = [
            sockaddrIPv6Loopback(),
            sockaddrIPv4("169.254.1.2"),
            Data([1, 2, 3]),
            sockaddrIPv4("192.168.1.20"),
        ]
        XCTAssertEqual(BonjourAddressPicker.ipv4Strings(from: addresses), ["169.254.1.2", "192.168.1.20"])
        XCTAssertEqual(BonjourAddressPicker.pick(BonjourAddressPicker.ipv4Strings(from: addresses)),
                       "192.168.1.20")
    }

    // MARK: - one row per Mac, the better address wins

    private func host(_ name: String, _ ip: String, did: String? = "MAC-1") -> DiscoveredHost {
        DiscoveredHost(name: name, host: ip, port: 8765, deviceID: did)
    }

    func test_merging_aRoutableAddressReplacesTheLinkLocalRow() {
        let first = BonjourBrowser.merging([], with: host("Studio", "169.254.1.2"))
        let merged = BonjourBrowser.merging(first, with: host("Studio", "192.168.1.20"))
        XCTAssertEqual(merged.map(\.host), ["192.168.1.20"], "one row for one Mac, on the routable address")
    }

    func test_merging_aLinkLocalAddressNeverReplacesARoutableRow() {
        let first = BonjourBrowser.merging([], with: host("Studio", "192.168.1.20"))
        let merged = BonjourBrowser.merging(first, with: host("Studio", "169.254.1.2"))
        XCTAssertEqual(merged.map(\.host), ["192.168.1.20"])
    }

    func test_merging_theSameAddressKeepsTheRowAndLearnsItsDeviceID() {
        let first = BonjourBrowser.merging([], with: host("Studio", "192.168.1.20", did: nil))
        let merged = BonjourBrowser.merging(first, with: host("Studio", "192.168.1.20", did: "MAC-1"))
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, first[0].id, "a repeat resolve must not churn the row's identity")
        XCTAssertEqual(merged[0].deviceID, "MAC-1")
    }

    func test_merging_keepsDifferentMacsApart() {
        var hosts = BonjourBrowser.merging([], with: host("Studio", "192.168.1.20", did: "MAC-1"))
        hosts = BonjourBrowser.merging(hosts, with: host("Laptop", "192.168.1.30", did: "MAC-2"))
        hosts = BonjourBrowser.merging(hosts, with: host("Laptop", "192.168.1.31", did: "MAC-3"))
        XCTAssertEqual(hosts.map(\.deviceID), ["MAC-1", "MAC-2", "MAC-3"],
                       "two device ids are two Macs, even under one service name")
    }

    // MARK: - DiscoveredHostFilter (step 6)

    func test_filter_listsUnknownMacs_andPairedMacsWhoseRowIsNotConnected() {
        let paired = [
            PairedBackend(id: "MAC-DOWN", url: "ws://169.254.1.2:8765", name: "Studio"),
            PairedBackend(id: "MAC-UP", url: "ws://192.168.1.30:8765", name: "Laptop"),
        ]
        let hosts = [
            host("Studio", "192.168.1.20", did: "MAC-DOWN"),
            host("Laptop", "192.168.1.30", did: "MAC-UP"),
            host("Guest", "192.168.1.40", did: "MAC-NEW"),
            host("Old", "192.168.1.50", did: nil),
        ]

        let visible = DiscoveredHostFilter.visible(hosts: hosts, paired: paired,
                                                   connectedBackendIDs: ["MAC-UP"])

        XCTAssertEqual(visible.map(\.name), ["Studio", "Guest", "Old"],
                       "a paired Mac is offered while its row is down, hidden while it is connected")
    }
}
