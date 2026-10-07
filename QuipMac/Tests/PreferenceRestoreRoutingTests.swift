import XCTest
@testable import Quip

/// A `preferences_request` gets exactly one reply, addressed to the device
/// that asked, carrying that device's own snapshot (US-014).
///
/// The socket half — `sendToClient` to the requesting connection instead of
/// `broadcast` — cannot be exercised without an `NWConnection`, so the part
/// that decides WHAT goes back and TO WHOM is pure and locked here.
final class PreferenceRestoreRoutingTests: XCTestCase {

    private func blob(_ snapshot: PreferencesSnapshot) throws -> Data {
        try JSONEncoder().encode(snapshot)
    }

    func test_replyNamesTheRequestingDeviceAndCarriesItsSnapshot() throws {
        var saved = PreferencesSnapshot()
        saved.enabledQuickButtons = "/btw,/help,Y,N"
        saved.terminalTextSize = 15

        let reply = PreferenceRestoreRouting.reply(for: "device-A", blob: try blob(saved))

        XCTAssertEqual(reply.outcome, .restored)
        XCTAssertEqual(reply.message.deviceID, "device-A")
        XCTAssertEqual(reply.message.type, "preferences_restore")
        XCTAssertEqual(reply.message.preferences, saved)
    }

    func test_noBackupStillRepliesWithDefaultsToTheRequester() {
        let reply = PreferenceRestoreRouting.reply(for: "device-A", blob: nil)

        XCTAssertEqual(reply.outcome, .noBackup)
        XCTAssertEqual(reply.message.deviceID, "device-A")
        XCTAssertEqual(reply.message.preferences, PreferencesSnapshot(),
                       "no backup must answer with defaults so the phone stops waiting")
    }

    func test_undecodableBackupFallsBackToDefaultsAndSaysSo() {
        let garbage = Data("not json".utf8)
        let reply = PreferenceRestoreRouting.reply(for: "device-A", blob: garbage)

        guard case .undecodable(let bytes, let error) = reply.outcome else {
            XCTFail("expected .undecodable, got \(reply.outcome)"); return
        }
        XCTAssertEqual(bytes, garbage.count)
        XCTAssertFalse(error.isEmpty)
        XCTAssertEqual(reply.message.deviceID, "device-A")
        XCTAssertEqual(reply.message.preferences, PreferencesSnapshot())
    }

    /// Two devices asking back to back each get their own reply, addressed to
    /// themselves. This is the shape the old `broadcast` broke: B's reply must
    /// never be something A could mistake for its own.
    func test_twoRequestersGetTwoRepliesEachAddressedToItself() throws {
        var forA = PreferencesSnapshot(); forA.enabledQuickButtons = "A"
        var forB = PreferencesSnapshot(); forB.enabledQuickButtons = "B"

        let replyA = PreferenceRestoreRouting.reply(for: "device-A", blob: try blob(forA))
        let replyB = PreferenceRestoreRouting.reply(for: "device-B", blob: try blob(forB))

        XCTAssertEqual(replyA.message.deviceID, "device-A")
        XCTAssertEqual(replyA.message.preferences.enabledQuickButtons, "A")
        XCTAssertEqual(replyB.message.deviceID, "device-B")
        XCTAssertEqual(replyB.message.preferences.enabledQuickButtons, "B")
        XCTAssertNotEqual(replyA.message.deviceID, replyB.message.deviceID)
    }

    /// The wire form carries the id, so a phone can drop a restore that is
    /// not for it (the iOS half of US-014).
    func test_wireFormCarriesTheDeviceID() throws {
        let reply = PreferenceRestoreRouting.reply(for: "device-A", blob: nil)
        let json = try JSONEncoder().encode(reply.message)
        let decoded = try JSONDecoder().decode(PreferenceRestoreMessage.self, from: json)
        XCTAssertEqual(decoded.deviceID, "device-A")
        XCTAssertEqual(decoded.type, "preferences_restore")
    }
}
