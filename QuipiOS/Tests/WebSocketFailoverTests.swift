import XCTest
import Network
@testable import Quip

/// PRD 2026-10-07, US-012 step 3: a URL that worked once is no longer
/// redialed forever. It is left after two failures in a row, or at once on an
/// address-class error, and running out of URLs wraps to the first and tells
/// the connection manager. No socket is opened: the client's cursor is placed
/// directly and failures are fed to `handleDisconnect`.
@MainActor
final class WebSocketFailoverTests: XCTestCase {

    private let u1 = URL(string: "ws://169.254.1.2:8765")!
    private let u2 = URL(string: "ws://192.168.1.20:8765")!
    private let u3 = URL(string: "ws://100.64.0.1:8765")!

    private func posix(_ code: Int) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: code)
    }

    // MARK: - URLFailoverCursor

    func test_cursor_aURLThatNeverAuthenticatedIsLeftOnItsFirstFailure() {
        var cursor = URLFailoverCursor(urls: [u1, u2])
        XCTAssertEqual(cursor.noteFailure(addressClassError: false), .advanced)
        XCTAssertEqual(cursor.current, u2)
    }

    func test_cursor_aURLThatWorkedGetsOneRetry_thenIsLeft() {
        var cursor = URLFailoverCursor(urls: [u1, u2])
        cursor.noteAuthenticated()
        XCTAssertEqual(cursor.noteFailure(addressClassError: false), .retry, "a brief drop retries the same URL")
        XCTAssertEqual(cursor.current, u1)
        XCTAssertEqual(cursor.noteFailure(addressClassError: false), .advanced)
        XCTAssertEqual(cursor.current, u2)
    }

    func test_cursor_anAddressClassErrorLeavesAWorkingURLAtOnce() {
        var cursor = URLFailoverCursor(urls: [u1, u2])
        cursor.noteAuthenticated()
        XCTAssertEqual(cursor.noteFailure(addressClassError: true), .advanced)
        XCTAssertEqual(cursor.current, u2)
    }

    func test_cursor_authenticatingAgainResetsTheCount() {
        var cursor = URLFailoverCursor(urls: [u1, u2])
        cursor.noteAuthenticated()
        XCTAssertEqual(cursor.noteFailure(addressClassError: false), .retry)
        cursor.noteAuthenticated()
        XCTAssertEqual(cursor.noteFailure(addressClassError: false), .retry,
                       "failures count only since the URL last authenticated")
    }

    func test_cursor_leavingTheLastURLWrapsToTheFirst() {
        var cursor = URLFailoverCursor(urls: [u1, u2, u3])
        XCTAssertEqual(cursor.noteFailure(addressClassError: false), .advanced)
        XCTAssertEqual(cursor.noteFailure(addressClassError: false), .advanced)
        XCTAssertEqual(cursor.noteFailure(addressClassError: false), .wrapped)
        XCTAssertEqual(cursor.current, u1)
        XCTAssertEqual(cursor.index, 0)
    }

    func test_cursor_aSingleURLWrapsOntoItself() {
        var cursor = URLFailoverCursor(urls: [u1])
        cursor.noteAuthenticated()
        XCTAssertEqual(cursor.noteFailure(addressClassError: false), .retry)
        XCTAssertEqual(cursor.noteFailure(addressClassError: false), .wrapped)
        XCTAssertEqual(cursor.current, u1)
    }

    func test_cursor_emptyListOnlyRetries() {
        var cursor = URLFailoverCursor()
        XCTAssertEqual(cursor.noteFailure(addressClassError: true), .retry)
        XCTAssertNil(cursor.current)
    }

    func test_cursor_rewindToPrimary() {
        var cursor = URLFailoverCursor(urls: [u1, u2])
        XCTAssertFalse(cursor.rewindToPrimary(), "already on the primary")
        _ = cursor.noteFailure(addressClassError: false)
        XCTAssertTrue(cursor.rewindToPrimary())
        XCTAssertEqual(cursor.current, u1)
    }

    // MARK: - WebSocketClient, no socket

    private func authenticatedClient(on urls: [URL]) -> WebSocketClient {
        let client = WebSocketClient()
        client.failover = URLFailoverCursor(urls: urls)
        client.serverURL = urls.first
        client.handleMessage(Data(#"{"type":"auth_result","success":true}"#.utf8))
        // Cancels the reconnects handleDisconnect schedules, so nothing dials.
        addTeardownBlock { @MainActor in client.disconnect() }
        return client
    }

    func test_client_aURLThatConnectedOnceThenFailsTwice_movesToTheNextURL() {
        let client = authenticatedClient(on: [u1, u2])

        client.handleDisconnect()
        XCTAssertEqual(client.serverURL, u1, "one failure of a working URL retries it")
        client.handleDisconnect()

        XCTAssertEqual(client.serverURL, u2)
    }

    func test_client_aSingleAddressClassErrorMovesOnAtOnce() {
        let client = authenticatedClient(on: [u1, u2])

        client.handleDisconnect(error: posix(49))   // EADDRNOTAVAIL: the interface went away

        XCTAssertEqual(client.serverURL, u2)
    }

    func test_client_exhaustingTheListWrapsToTheFirstAndReportsItOnce() {
        let client = WebSocketClient()
        client.failover = URLFailoverCursor(urls: [u1, u2])
        client.serverURL = u1
        addTeardownBlock { @MainActor in client.disconnect() }
        var exhausted = 0
        client.onURLListExhausted = { exhausted += 1 }

        client.handleDisconnect()
        XCTAssertEqual(client.serverURL, u2)
        XCTAssertEqual(exhausted, 0)
        client.handleDisconnect()

        XCTAssertEqual(client.serverURL, u1, "wrapped back to index 0")
        XCTAssertEqual(client.failover.index, 0)
        XCTAssertEqual(exhausted, 1)
    }

    func test_client_anIntentionalDisconnectCountsNothing() {
        let client = authenticatedClient(on: [u1, u2])
        client.disconnect()

        client.handleDisconnect(error: posix(49))

        XCTAssertEqual(client.serverURL, u1)
    }

    // MARK: - a replaced socket's late completion

    /// A WebSocket server on 127.0.0.1 inside the test process (nothing
    /// leaves the machine) that answers pings, so the client can connect.
    private final class LoopbackWebSocketServer {
        private let listener: NWListener
        private var connections: [NWConnection] = []

        init() throws {
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = true
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.connections.append(connection)
                connection.start(queue: .main)
            }
            listener.start(queue: .main)
        }

        var port: UInt16 { listener.port?.rawValue ?? 0 }

        func stop() {
            connections.forEach { $0.cancel() }
            listener.cancel()
        }
    }

    private struct TimedOut: Error {}

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                throw TimedOut()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A socket the client has replaced still completes its pending receive
    /// (cancelling a connected task reports POSIX 57). That late failure used
    /// to run handleDisconnect against the attempt that replaced it, which
    /// skipped straight to the next URL: a manager reconnect never stayed on
    /// the URL it preferred, and with the failure count it would also have
    /// counted against a URL that had not failed.
    func test_aReplacedSocketsLateCompletion_leavesTheNewAttemptOnItsURL() async throws {
        let server = try LoopbackWebSocketServer()
        addTeardownBlock { server.stop() }
        try await waitUntil("the loopback listener") { server.port != 0 }
        let good = URL(string: "ws://127.0.0.1:\(server.port)")!
        let unused = URL(string: "ws://127.0.0.1:9")!
        let client = WebSocketClient()
        addTeardownBlock { @MainActor in client.disconnect() }
        var exhausted = 0
        client.onURLListExhausted = { exhausted += 1 }

        client.connect(toURLs: [good, unused])
        try await waitUntil("the first connection") { client.isConnected }
        // What every manager reconnect does: drop the live socket, dial again.
        client.disconnect()
        client.connect(toURLs: [good, unused])
        try await waitUntil("the second connection") { client.isConnected }
        try await Task.sleep(nanoseconds: 400_000_000)   // the old socket's completion lands

        // Without the guard, the late completion advanced to `unused`,
        // wrapped, and redialed `good` a second later: the end state looked
        // fine, so assert on what it changed along the way.
        XCTAssertTrue(client.connectionMetrics.disconnectsByReason.isEmpty, "nothing ran handleDisconnect")
        XCTAssertEqual(client.connectionMetrics.failovers, 0, "nothing moved off the URL")
        XCTAssertEqual(client.connectionMetrics.connectAttempts, 2, "one dial per connect, no redial")
        XCTAssertEqual(exhausted, 0)
        XCTAssertEqual(client.serverURL, good)
        XCTAssertTrue(client.isConnected)
    }

    // MARK: - which errors are address-class

    func test_addressClass_posixDomainCodes() {
        for code in [49, 50, 51, 65] {
            XCTAssertTrue(WebSocketClient.isAddressClassError(posix(code)), "POSIX \(code)")
        }
        XCTAssertFalse(WebSocketClient.isAddressClassError(posix(54)), "reset by peer is not an address problem")
        XCTAssertFalse(WebSocketClient.isAddressClassError(posix(60)), "a timeout is not one either")
        XCTAssertFalse(WebSocketClient.isAddressClassError(nil))
    }

    func test_addressClass_findsTheErrnoWhereverItWasPut() {
        let wrapped = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                              userInfo: [NSUnderlyingErrorKey: posix(51)])
        XCTAssertEqual(WebSocketClient.posixCode(of: wrapped), 51)
        XCTAssertTrue(WebSocketClient.isAddressClassError(wrapped))

        let streamKeys = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                                 userInfo: ["_kCFStreamErrorDomainKey": 1, "_kCFStreamErrorCodeKey": 65])
        XCTAssertTrue(WebSocketClient.isAddressClassError(streamKeys))

        XCTAssertTrue(WebSocketClient.isAddressClassError(NWError.posix(.ENETDOWN)))
        XCTAssertFalse(WebSocketClient.isAddressClassError(NWError.dns(-65554)))
    }

    func test_addressClass_aBareURLErrorHasNoErrno() {
        // What URLSession reports for a dial it could not complete.
        let refused = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        XCTAssertNil(WebSocketClient.posixCode(of: refused))
        XCTAssertFalse(WebSocketClient.isAddressClassError(refused))
    }
}
