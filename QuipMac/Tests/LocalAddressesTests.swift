import XCTest
@testable import Quip

/// Locks `WebSocketServer.isPrivateIPv4` — the RFC1918 gate that decides which
/// interface addresses get advertised to the phone as `localURLs` for the
/// "Use Local Network" switch. Must accept LAN ranges and reject loopback,
/// link-local, Tailscale CGNAT, and malformed input.
final class LocalAddressesTests: XCTestCase {

    func testAcceptsRFC1918Ranges() {
        XCTAssertTrue(WebSocketServer.isPrivateIPv4("10.0.0.5"))
        XCTAssertTrue(WebSocketServer.isPrivateIPv4("10.255.255.255"))
        XCTAssertTrue(WebSocketServer.isPrivateIPv4("192.168.1.50"))
        XCTAssertTrue(WebSocketServer.isPrivateIPv4("172.16.0.1"))
        XCTAssertTrue(WebSocketServer.isPrivateIPv4("172.31.255.1"))
    }

    func testRejectsNonLAN() {
        XCTAssertFalse(WebSocketServer.isPrivateIPv4("127.0.0.1"), "loopback")
        XCTAssertFalse(WebSocketServer.isPrivateIPv4("169.254.1.1"), "link-local")
        XCTAssertFalse(WebSocketServer.isPrivateIPv4("100.120.141.122"), "Tailscale CGNAT")
        XCTAssertFalse(WebSocketServer.isPrivateIPv4("172.32.0.1"), "just outside 16-31")
        XCTAssertFalse(WebSocketServer.isPrivateIPv4("172.15.0.1"), "just below 16")
        XCTAssertFalse(WebSocketServer.isPrivateIPv4("8.8.8.8"), "public")
    }

    func testRejectsMalformed() {
        XCTAssertFalse(WebSocketServer.isPrivateIPv4("not.an.ip.addr"))
        XCTAssertFalse(WebSocketServer.isPrivateIPv4("192.168.1"), "too few octets")
        XCTAssertFalse(WebSocketServer.isPrivateIPv4("192.168.1.256"), "octet out of range")
        XCTAssertFalse(WebSocketServer.isPrivateIPv4(""))
    }

    // MARK: - Shared classifier (US-005: single source of truth)

    /// `WebSocketServer.isPrivateIPv4` now delegates to the shared
    /// `NetworkClassifier` in `Shared/`, compiled into BOTH the QuipMac and
    /// QuipiOS targets. Lock that the Mac forwards to it verbatim so the two
    /// peers' RFC1918 range logic can never diverge.
    func testDelegatesToSharedClassifier() {
        for ip in ["10.0.0.5", "192.168.1.50", "172.16.0.1", "172.31.255.1",
                   "127.0.0.1", "169.254.1.1", "100.120.141.122", "172.32.0.1",
                   "8.8.8.8", "192.168.1", "192.168.1.256", "not.an.ip.addr", ""] {
            XCTAssertEqual(WebSocketServer.isPrivateIPv4(ip),
                           NetworkClassifier.isRFC1918IPv4(ip),
                           "isPrivateIPv4 must forward to NetworkClassifier for \(ip)")
        }
    }

    // MARK: - Primary-interface gate (US-003: drop bridge/VM/tunnel LAN IPs)

    /// Only primary Wi-Fi/Ethernet (`en*`) interfaces are advertised as LAN
    /// URLs. A Mac running Internet Sharing or a VM has a private-IPv4 address
    /// on `bridge100` / `vmenet0` that the phone can NOT reach — advertising it
    /// dead-ends the "Use Local Network" switch, so those interfaces are
    /// excluded even though `isPrivateIPv4` accepts their address.
    func testAcceptsPrimaryEthernetInterfaces() {
        XCTAssertTrue(WebSocketServer.isPrimaryLANInterface("en0"), "Wi-Fi")
        XCTAssertTrue(WebSocketServer.isPrimaryLANInterface("en1"), "Ethernet / adapter")
        XCTAssertTrue(WebSocketServer.isPrimaryLANInterface("en10"), "USB/Thunderbolt Ethernet")
    }

    func testRejectsBridgeAndVirtualInterfaces() {
        XCTAssertFalse(WebSocketServer.isPrimaryLANInterface("bridge100"), "Internet-Sharing / Thunderbolt bridge")
        XCTAssertFalse(WebSocketServer.isPrimaryLANInterface("bridge0"), "bridge")
        XCTAssertFalse(WebSocketServer.isPrimaryLANInterface("vmenet0"), "virtualization host interface")
        XCTAssertFalse(WebSocketServer.isPrimaryLANInterface("vnic0"), "VM NIC")
        XCTAssertFalse(WebSocketServer.isPrimaryLANInterface("utun3"), "VPN / Tailscale tunnel")
        XCTAssertFalse(WebSocketServer.isPrimaryLANInterface("awdl0"), "Apple Wireless Direct Link")
        XCTAssertFalse(WebSocketServer.isPrimaryLANInterface("llw0"), "low-latency WLAN")
        XCTAssertFalse(WebSocketServer.isPrimaryLANInterface("lo0"), "loopback")
    }
}
