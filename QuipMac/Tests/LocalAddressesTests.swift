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
}
