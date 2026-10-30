import XCTest
@testable import Quip

/// Q-88 US-011: one tap opens the remote-desktop app, window first.
@MainActor
final class RemoteInFlowTests: XCTestCase {
    private final class FakeOpener: URLOpener {
        var installed = true
        var opened: [URL] = []
        var onOpen: () -> Void = {}
        func open(_ url: URL) async -> Bool {
            onOpen()
            opened.append(url)
            return installed
        }
    }

    private let host = "studio.tail1234.ts.net"
    private var opener = FakeOpener()
    private var clock = ContinuousClock.now
    private var events: [String] = []

    /// Sleep only moves the fake clock, so a timeout takes exactly `echoWait`.
    private func makeFlow() -> RemoteInFlow {
        opener.onOpen = { [unowned self] in events.append("open") }
        return RemoteInFlow(opener: opener,
                            sleep: { [unowned self] d in clock = clock.advanced(by: d) },
                            now: { [unowned self] in clock })
    }

    private func run(_ flow: RemoteInFlow, settings: RemoteInSettings = RemoteInSettings(),
                     host: String? = nil, windowId: String? = "W2", alreadyFront: Bool = false,
                     echo: Bool = false) async -> RemoteInFlow.Outcome {
        await flow.run(settings: settings, host: host ?? self.host, name: "Studio",
                       windowId: windowId, alreadyFront: alreadyFront) { [unowned self] id in
            events.append("select \(id)")
            if echo { Task { @MainActor in flow.frontmostChanged(id) } }
        }
    }

    func test_selectsTheWindow_thenOpens() async {
        let flow = makeFlow()
        let o = await run(flow, echo: true)
        XCTAssertEqual(events, ["select W2", "open"])
        XCTAssertEqual(o.result, .opened)
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["vnc://studio.tail1234.ts.net"])
    }

    func test_echo_endsTheWaitEarly() async {
        // A real sleep here, so only the echo can end the wait quickly.
        opener.onOpen = { [unowned self] in events.append("open") }
        let flow = RemoteInFlow(opener: opener, sleep: { _ in try? await Task.sleep(for: .seconds(5)) })
        let started = ContinuousClock.now
        let o = await run(flow, echo: true)
        XCTAssertEqual(o.result, .opened)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    func test_noEcho_timesOut_andStillOpens() async {
        let flow = makeFlow()
        let o = await run(flow)
        XCTAssertEqual(events, ["select W2", "open"])
        XCTAssertEqual(o.result, .opened)
        XCTAssertEqual(o.waitedMs, 500)
    }

    func test_alreadyFront_orWholeMac_doesNotWait() async {
        let flow = makeFlow()
        let front = await run(flow, alreadyFront: true)
        XCTAssertEqual(front.waitedMs, 0)
        events = []
        let mac = await run(flow, windowId: nil)
        XCTAssertEqual(events, ["open"], "a whole Mac selects no window")
        XCTAssertEqual(mac.waitedMs, 0)
    }

    func test_noApp() async {
        opener.installed = false
        let flow = makeFlow()
        let o = await run(flow, alreadyFront: true)
        XCTAssertEqual(o.result, .noApp)
        XCTAssertEqual(o.url?.scheme, "vnc")
    }

    func test_noHost_neitherSelectsNorOpens() async {
        let flow = makeFlow()
        let o = await run(flow, host: "")
        XCTAssertEqual(o.result, .noHost)
        XCTAssertEqual(events, [])
        XCTAssertTrue(o.logLine.contains("host_kind=none result=no_host"))
    }

    func test_logLine_namesTheKind_neverTheHost() async {
        let flow = makeFlow()
        let o = await run(flow, alreadyFront: true)
        XCTAssertEqual(o.logLine, "remote_in preset=vnc host_kind=tailscale result=opened waited_ms=0")
        XCTAssertFalse(o.logLine.contains("studio"))
    }

    func test_hostKind() {
        XCTAssertEqual(RemoteInFlow.hostKind(template: "vnc://{host}", host: "100.70.1.2"), "tailscale")
        XCTAssertEqual(RemoteInFlow.hostKind(template: "vnc://{host}", host: "192.168.1.5"), "lan")
        XCTAssertEqual(RemoteInFlow.hostKind(template: "vnc://{host}", host: "studio.local"), "lan")
        XCTAssertEqual(RemoteInFlow.hostKind(template: "vnc://{host}", host: "example.com"), "custom")
        XCTAssertEqual(RemoteInFlow.hostKind(template: "berriscope://open?saved={name}", host: ""), "name")
    }

    // MARK: Berriscope is the owner's own app

    func test_berriscope_listedOnlyWhenInstalled_orAlreadyChosen() {
        let all = RemoteInPreset.allCases
        XCTAssertFalse(RemoteInPreset.choices(berriscopeInstalled: false, current: .vnc).contains(.berriscope))
        XCTAssertEqual(RemoteInPreset.choices(berriscopeInstalled: true, current: .vnc), all)
        XCTAssertTrue(RemoteInPreset.choices(berriscopeInstalled: false, current: .berriscope).contains(.berriscope))
    }
}
