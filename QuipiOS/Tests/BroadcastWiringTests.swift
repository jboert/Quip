import XCTest
@testable import Quip

/// PRD broadcast-and-search US-109: Broadcast as a Quick Button, and a saved
/// row holding a slot this build does not know.
final class BroadcastQuickButtonTests: XCTestCase {

    func test_theBroadcastKeyOpensTheSheetAndSendsNothing() {
        guard case .openBroadcast = QuickButton.broadcast.action else {
            return XCTFail("the Broadcast key must open the sheet, not send")
        }
        XCTAssertFalse(QuickButton.broadcast.isSlashCommand)
        XCTAssertEqual(QuickButton.broadcast.category, .app)
        XCTAssertEqual(QuickButton.broadcast.systemImage, "dot.radiowaves.left.and.right",
                       "the same icon as the Broadcast bar")
    }

    func test_theAddSheetFindsBroadcastByNameAndByWhatItDoes() {
        XCTAssertEqual(QuickButtonSearch.filter(QuickButton.allCases, query: "broadcast").first, .broadcast)
        XCTAssertEqual(QuickButtonSearch.filter(QuickButton.allCases, query: "several terminals").first, .broadcast)
    }

    func test_aRowWithBroadcastRoundTrips() {
        let slots: [QuickSlot] = [.builtin(.yes), .builtin(.broadcast), .promptsPicker]
        var logs: [String] = []
        let decoded = QuickSlotStore.decode(QuickSlotStore.encode(slots), log: { logs.append($0) }, latch: LogLatch())
        XCTAssertEqual(decoded, slots)
        XCTAssertTrue(logs.isEmpty, "a row this build knows must not log. Got \(logs)")
    }

    /// What a build meets when a newer build's row is restored from the Mac.
    func test_aSlotThisBuildDoesNotKnowIsSkippedAndTheRestKept() {
        let raw = #"[{"kind":"builtin","button":"yes"},{"kind":"builtin","button":"teleport"},{"kind":"hologram"},{"kind":"promptsPicker"}]"#
        let latch = LogLatch()
        var logs: [String] = []

        let decoded = QuickSlotStore.decode(raw, log: { logs.append($0) }, latch: latch)

        XCTAssertEqual(decoded, [.builtin(.yes), .promptsPicker])
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs.first?.contains("skipped 2 of 4") == true, "Got \(logs)")

        for _ in 0..<50 { _ = QuickSlotStore.decode(raw, log: { logs.append($0) }, latch: latch) }
        XCTAssertEqual(logs.count, 1, "re-rendering the same row must not log again")
    }

    func test_aRowThatIsNotAListStillFallsBackLoudly() {
        var logs: [String] = []
        let decoded = QuickSlotStore.decode(#"{"kind":"builtin","button":"yes"}"#,
                                            log: { logs.append($0) }, latch: LogLatch())
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertTrue(logs.first?.contains("quickSlots decode FAILED") == true, "Got \(logs)")
    }
}

/// PRD broadcast-and-search US-111: every `send_text_ack` reaches the main
/// screen, which counts it toward the last broadcast.
@MainActor
final class BroadcastAckWiringTests: XCTestCase {

    private func ack(_ id: UUID) throws -> Data {
        try JSONEncoder().encode(SendTextAckMessage(messageId: id, injectMs: 1, totalMs: 2, path: "sendText"))
    }

    /// The latency tracker forgets ids beyond its cap and never saw
    /// `paste_prompt` ids; a broadcast still needs those acks.
    func test_theClientReportsAnAckItWasNotTiming() throws {
        let client = WebSocketClient()
        var acked: [UUID] = []
        client.onSendTextAck = { acked.append($0) }
        let id = UUID()

        client.handleMessage(try ack(id))

        XCTAssertEqual(acked, [id])
    }

    /// Saves and restores the pairing keys `ensureImplicitDefault` writes.
    private final class Sandbox {
        private let keys = ["pairedBackendsData", "activeBackendID"]
        private var saved: [String: Any] = [:]

        init() {
            for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        }

        func restore() {
            for key in keys {
                if let value = saved[key] {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
    }

    /// Without the bridge in `BackendConnectionManager.wire`, the host's
    /// callback would silently never fire.
    func test_theManagerForwardsASessionsAckWithTheSession() throws {
        let sandbox = Sandbox()
        addTeardownBlock { sandbox.restore() }
        let manager = BackendConnectionManager()
        manager.ensureImplicitDefault(url: "ws://127.0.0.1:9")
        let session = try XCTUnwrap(manager.sessions[manager.activeBackendID])
        var received: [(backendID: String, messageID: UUID)] = []
        manager.onSendTextAck = { session, id in received.append((session.backendID, id)) }
        let id = UUID()

        session.client.handleMessage(try ack(id))

        XCTAssertEqual(received.map(\.messageID), [id])
        XCTAssertEqual(received.first?.backendID, session.backendID)
    }
}
