import XCTest
@testable import Quip

/// Q-86: the Mac's build arrives on auth and never outlives the connection.
/// No socket is opened: frames are fed to `handleMessage`, the drop to
/// `handleDisconnect`, as WebSocketFailoverTests does.
@MainActor
final class WebSocketClientMacBuildTests: XCTestCase {

    private let frame = Data(#"{"type":"mac_build","short":"1.5.7","build":"1","commit":"0038c48","number":"1642","date":"2026-10-27 19:55","deviceID":"mac-1"}"#.utf8)

    private func authenticatedClient() -> WebSocketClient {
        let client = WebSocketClient()
        client.failover = URLFailoverCursor(urls: [URL(string: "ws://192.168.1.20:8765")!])
        client.serverURL = client.failover.current
        client.handleMessage(Data(#"{"type":"auth_result","success":true}"#.utf8))
        // Cancels the reconnects handleDisconnect schedules, so nothing dials.
        addTeardownBlock { @MainActor in client.disconnect() }
        return client
    }

    func test_aMacBuildFrameSetsMacBuild_andTellsTheCallback() {
        let client = authenticatedClient()
        var seen: MacBuildMessage?
        client.onMacBuild = { seen = $0 }

        client.handleMessage(frame)

        XCTAssertEqual(client.macBuild?.commit, "0038c48")
        XCTAssertEqual(client.macBuild.map { BuildInfo.shortDisplay($0.stamp) }, "1.5.7 (1642) 0038c48")
        XCTAssertEqual(seen, client.macBuild)
    }

    func test_beforeAuth_aMacBuildFrameIsIgnored() {
        let client = WebSocketClient()
        addTeardownBlock { @MainActor in client.disconnect() }

        client.handleMessage(frame)

        XCTAssertNil(client.macBuild)
    }

    func test_handleDisconnectClearsMacBuild() {
        let client = authenticatedClient()
        client.handleMessage(frame)
        XCTAssertNotNil(client.macBuild)

        client.handleDisconnect()

        XCTAssertNil(client.macBuild, "a reconnect to another Mac must never show the old row")
    }

    func test_disconnectClearsMacBuild() {
        let client = authenticatedClient()
        client.handleMessage(frame)

        client.disconnect()

        XCTAssertNil(client.macBuild)
    }
}
