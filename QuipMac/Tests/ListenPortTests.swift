import XCTest
@testable import Quip

/// The WebSocket port is a constant, not a setting. A stale `wsPort` default
/// left behind by the old Connection-pane field must not leak into any URL the
/// Mac hands the phone — that URL would point at a port nothing listens on.
final class ListenPortTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(9000, forKey: "wsPort")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "wsPort")
        super.tearDown()
    }

    func test_tailscaleURL_ignoresStaleWsPortDefault() {
        XCTAssertEqual(TailscaleService.webSocketURL(host: "mac.tail.ts.net"),
                       "ws://mac.tail.ts.net:8765")
    }

    func test_localWebSocketURLs_allUseListenPort() {
        // Empty on a host with no private-IPv4 `en*` interface (some CI
        // runners); the per-URL check is what matters where there are URLs.
        for url in WebSocketServer.localWebSocketURLs() {
            XCTAssertTrue(url.hasSuffix(":8765"), "\(url) does not use the listen port")
        }
    }

    func test_listenPort_is8765() {
        XCTAssertEqual(WebSocketServer.listenPort, 8765)
    }
}
