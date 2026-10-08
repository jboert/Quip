import XCTest
@testable import Quip

/// PRD 2026-10-07, US-012 steps 2, 4 and 5: a link-local URL is a LAN address
/// of last resort, the Mac's announced URLs always land in its row, and a
/// client that ran out of URLs makes the manager look for the Mac again.
/// Nothing here dials: rediscovery uses a fake browser, and the client is
/// either already cycling the row's URLs or already back on its own.
@MainActor
final class LinkLocalRecoveryTests: XCTestCase {

    private let linkLocal = "ws://169.254.1.2:8765"
    private let lan = "ws://192.168.1.20:8765"
    private let ts = "ws://100.64.0.1:8765"
    private let tunnel = "wss://abc.trycloudflare.com"

    private func urls(_ strings: [String]) -> [URL] { strings.compactMap(URL.init(string:)) }

    /// Saves the pairing keys the manager writes, hands out throwaway backend
    /// ids, and undoes both when the test ends.
    private final class Sandbox {
        private let keys = ["pairedBackendsData", "activeBackendID"]
        private var saved: [String: Any] = [:]
        private var ids: [String] = []

        init() {
            for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        }

        func newID() -> String { track(UUID().uuidString) }

        @discardableResult
        func track(_ id: String) -> String {
            ids.append(id)
            return id
        }

        func restore() {
            for id in ids { KeychainBackendPINs.delete(backendID: id) }
            for key in keys {
                if let value = saved[key] {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
    }

    private func makeSandbox() -> Sandbox {
        let sandbox = Sandbox()
        addTeardownBlock { sandbox.restore() }
        return sandbox
    }

    private func deliverIdentity(_ deviceID: String, localURLs: [String], to session: BackendSession) throws {
        let message = DeviceIdentityMessage(deviceID: deviceID, deviceKind: "mac",
                                            displayName: "Mac", localURLs: localURLs)
        session.client.handleMessage(try JSONEncoder().encode(message))
    }

    // MARK: - Link-local is LAN-class, last (step 2)

    func test_linkLocalSortsAfterRFC1918AndBeforeTailscale() {
        let priority = BackendConnectionManager.urlPriority
        XCTAssertLessThan(priority(lan), priority(linkLocal))
        XCTAssertLessThan(priority(linkLocal), priority(ts))
        XCTAssertEqual(BackendConnectionManager.mergedURLOrder([linkLocal, tunnel, lan]),
                       [lan, linkLocal, tunnel])
        XCTAssertEqual(BackendConnectionManager.mergedURLOrder([linkLocal, tunnel, lan, ts]),
                       [ts, lan, linkLocal, tunnel], "Tailscale still leads")
    }

    func test_linkLocalIsLAN_andLabelledLocalNetwork() {
        let url = URL(string: linkLocal)!
        XCTAssertTrue(BackendConnectionManager.isLANURL(url))
        XCTAssertEqual(BackendConnectionManager.pathLabel(for: url), "Local network")
    }

    func test_announcedLANURLsReplaceALinkLocalURL() {
        XCTAssertEqual(BackendConnectionManager.urlsByRefreshingLocal([linkLocal], [lan]), [lan])
    }

    func test_theURLAnIdentityArrivedOverIsKept_last() {
        XCTAssertEqual(BackendConnectionManager.urlsByRefreshingLocal([linkLocal], [lan], keeping: linkLocal),
                       [lan, linkLocal])
    }

    func test_linkLocalIsNeverAUseLocalNetworkTarget() {
        XCTAssertNil(BackendConnectionManager.preferredLANURL(from: urls([ts, linkLocal])))
        let manager = BackendConnectionManager()
        manager.paired = [PairedBackend(id: "mac", url: ts, name: "Mac", fallbackURLs: [linkLocal])]
        XCTAssertNil(manager.lanURL(for: "mac"), "no tile for a switch that would do nothing")
    }

    // MARK: - Announced URLs land in the row (step 5)

    func test_aRowWhoseOnlyURLIsLinkLocal_getsTheAnnouncedURLsAheadOfIt() throws {
        let box = makeSandbox()
        let manager = BackendConnectionManager()
        manager.ensureImplicitDefault(url: linkLocal)
        let legacyID = box.track(manager.activeBackendID)
        let session = try XCTUnwrap(manager.sessions[legacyID])
        session.client.serverURL = URL(string: linkLocal)   // the identity arrives over it
        let realID = box.newID()

        try deliverIdentity(realID, localURLs: [lan], to: session)

        let row = try XCTUnwrap(manager.paired.first { $0.id == realID })
        XCTAssertEqual(row.urlsInOrder, [lan, linkLocal], "routable URL primary, link-local last")
    }

    func test_aMergedKeeperGetsTheAnnouncedURLs_andDropsItsStaleLinkLocal() throws {
        let box = makeSandbox()
        let keeper = box.newID()
        let stale = "ws://169.254.9.9:8765"
        let manager = BackendConnectionManager()
        manager.paired = [PairedBackend(id: keeper, url: stale, name: "Mac")]
        manager.ensureImplicitDefault(url: linkLocal)       // the Bonjour tap's temporary row
        let freshID = box.track(manager.activeBackendID)
        let fresh = try XCTUnwrap(manager.sessions[freshID])
        fresh.client.serverURL = URL(string: linkLocal)

        try deliverIdentity(keeper, localURLs: [lan], to: fresh)

        XCTAssertEqual(manager.paired.map(\.id), [keeper])
        XCTAssertEqual(manager.paired[0].urlsInOrder, [lan, linkLocal])
    }

    // MARK: - Rediscovery (step 4)

    private final class FakeBrowser: MacRediscovering {
        var discoveredHosts: [DiscoveredHost] = []
        private(set) var starts = 0
        private(set) var stops = 0
        var onStop: (() -> Void)?

        func startBrowsing() { starts += 1 }
        func stopBrowsing() {
            stops += 1
            onStop?()
        }
    }

    /// A manager with one enabled row on `rowURLs`, whose client is already
    /// cycling those same URLs, so a rediscovery that learns nothing new has
    /// nothing to dial.
    private func setUpRow(_ rowURLs: [String], box: Sandbox) throws
        -> (BackendConnectionManager, BackendSession, FakeBrowser) {
        let manager = BackendConnectionManager()
        manager.ensureImplicitDefault(url: rowURLs[0])
        let id = box.track(manager.activeBackendID)
        let i = try XCTUnwrap(manager.paired.firstIndex { $0.id == id })
        manager.paired[i].fallbackURLs = Array(rowURLs.dropFirst())
        let session = try XCTUnwrap(manager.sessions[id])
        session.client.failover = URLFailoverCursor(urls: urls(rowURLs))
        let browser = FakeBrowser()
        manager.makeRediscoveryBrowser = { browser }
        manager.rediscoveryWindow = 0
        addTeardownBlock { @MainActor in session.client.disconnect() }
        return (manager, session, browser)
    }

    func test_anExhaustedURLList_startsARediscovery() async throws {
        let box = makeSandbox()
        let (manager, session, browser) = try setUpRow([linkLocal], box: box)
        let ended = expectation(description: "the rediscovery browse ended")
        browser.onStop = { ended.fulfill() }

        session.client.onURLListExhausted?()

        XCTAssertEqual(browser.starts, 1, "wire(session:) must bridge onURLListExhausted")
        await fulfillment(of: [ended], timeout: 2)
        withExtendedLifetime(manager) {}
    }

    func test_rediscoveryRunsAtMostOncePer30sPerBackend() async throws {
        let box = makeSandbox()
        let (manager, session, browser) = try setUpRow([linkLocal], box: box)
        let t0 = Date()

        let first = manager.rediscover(after: session, now: t0)
        let tooSoon = manager.rediscover(after: session, now: t0.addingTimeInterval(10))
        let later = manager.rediscover(after: session, now: t0.addingTimeInterval(31))

        XCTAssertNotNil(first)
        XCTAssertNil(tooSoon)
        XCTAssertNotNil(later)
        XCTAssertEqual(browser.starts, 2)
        await first?.value
        await later?.value
    }

    func test_rediscoveryFoldsTheAddressBonjourFoundIntoTheRow() async throws {
        let box = makeSandbox()
        let (manager, session, browser) = try setUpRow([linkLocal], box: box)
        browser.discoveredHosts = [
            DiscoveredHost(name: "Studio", host: "192.168.1.20", port: 8765, deviceID: session.backendID),
        ]
        session.client.isAuthenticated = true   // came back on its own meanwhile: no reconnect

        await manager.rediscover(after: session)?.value

        let row = try XCTUnwrap(manager.paired.first { $0.id == session.backendID })
        XCTAssertEqual(row.urlsInOrder, [lan, linkLocal])
        XCTAssertEqual(browser.stops, 1)
    }

    func test_dialList_prefersTheAddressBonjourJustFound() {
        XCTAssertEqual(BackendConnectionManager.rediscoveryDialList(
            rowURLs: urls([ts, lan, linkLocal]), clientURLs: urls([linkLocal]), discovered: URL(string: lan)),
            urls([lan, ts, linkLocal]))
    }

    func test_dialList_otherwisePrefersTheRowsLANURL() {
        XCTAssertEqual(BackendConnectionManager.rediscoveryDialList(
            rowURLs: urls([ts, lan, linkLocal]), clientURLs: urls([linkLocal]), discovered: nil),
            urls([lan, ts, linkLocal]))
    }

    func test_dialList_isNilWhenNothingIsNew() {
        let row = urls([linkLocal])
        XCTAssertNil(BackendConnectionManager.rediscoveryDialList(rowURLs: row, clientURLs: row, discovered: nil))
        XCTAssertNil(BackendConnectionManager.rediscoveryDialList(rowURLs: row, clientURLs: row, discovered: row[0]),
                     "Bonjour found the URL the client is about to dial anyway")
    }

    func test_bestHost_prefersARoutableAddressOfThisMac() {
        let hosts = [
            DiscoveredHost(name: "Studio", host: "169.254.1.2", port: 8765, deviceID: "MAC-1"),
            DiscoveredHost(name: "Other", host: "192.168.1.30", port: 8765, deviceID: "MAC-2"),
            DiscoveredHost(name: "Studio", host: "192.168.1.20", port: 8765, deviceID: "MAC-1"),
        ]
        XCTAssertEqual(BackendConnectionManager.bestHost(for: "MAC-1", in: hosts)?.host, "192.168.1.20")
        XCTAssertNil(BackendConnectionManager.bestHost(for: "MAC-3", in: hosts))
    }

    func test_mayRediscover() {
        let t0 = Date()
        XCTAssertTrue(BackendConnectionManager.mayRediscover(lastAt: nil, now: t0))
        XCTAssertFalse(BackendConnectionManager.mayRediscover(lastAt: t0, now: t0.addingTimeInterval(29)))
        XCTAssertTrue(BackendConnectionManager.mayRediscover(lastAt: t0, now: t0.addingTimeInterval(30)))
    }
}
