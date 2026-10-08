import XCTest
@testable import Quip

/// PRD 2026-10-07, US-005: a PIN survives every path where two rows for the
/// same Mac collapse into one. Runs against the simulator test host's real
/// Keychain under throwaway UUID ids, and puts the real pairing keys back
/// after each test, so a run leaves no rows or PINs behind.
@MainActor
final class BackendPINCarryOverTests: XCTestCase {

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

    private func pin(_ id: String) -> String? {
        KeychainBackendPINs.read(backendID: id)
    }

    /// Delivers the Mac's `device_identity` to `session` the way the socket
    /// would, so the manager's per-session identity handler runs.
    private func deliverIdentity(_ deviceID: String, to session: BackendSession,
                                 localURLs: [String]? = nil) throws {
        let message = DeviceIdentityMessage(deviceID: deviceID, deviceKind: "mac",
                                            displayName: "Mac", localURLs: localURLs)
        session.client.handleMessage(try JSONEncoder().encode(message))
    }

    private let urlA = "ws://192.168.1.20:8765"
    private let urlB = "ws://10.0.0.5:8765"

    // MARK: - KeychainBackendPINs.carryOver

    func test_carryOver_fillsAKeeperThatHasNone_andDropsTheOldEntry() {
        let box = makeSandbox()
        let old = box.newID(), keeper = box.newID()
        KeychainBackendPINs.write(backendID: old, pin: "1234")

        XCTAssertTrue(KeychainBackendPINs.carryOver(from: old, to: keeper, preferOld: false))

        XCTAssertEqual(pin(keeper), "1234")
        XCTAssertNil(pin(old))
    }

    func test_carryOver_preferOld_replacesTheKeepersPIN() {
        let box = makeSandbox()
        let old = box.newID(), keeper = box.newID()
        KeychainBackendPINs.write(backendID: old, pin: "1234")
        KeychainBackendPINs.write(backendID: keeper, pin: "9999")

        XCTAssertTrue(KeychainBackendPINs.carryOver(from: old, to: keeper, preferOld: true))

        XCTAssertEqual(pin(keeper), "1234")
        XCTAssertNil(pin(old))
    }

    func test_carryOver_notPreferOld_keepsTheKeepersPIN() {
        let box = makeSandbox()
        let old = box.newID(), keeper = box.newID()
        KeychainBackendPINs.write(backendID: old, pin: "1234")
        KeychainBackendPINs.write(backendID: keeper, pin: "9999")

        XCTAssertFalse(KeychainBackendPINs.carryOver(from: old, to: keeper, preferOld: false))

        XCTAssertEqual(pin(keeper), "9999")
        XCTAssertNil(pin(old), "the merged-away row's entry is still cleaned up")
    }

    func test_carryOver_oldRowWithoutPIN_leavesTheKeeperAlone() {
        let box = makeSandbox()
        let old = box.newID(), keeper = box.newID()
        KeychainBackendPINs.write(backendID: keeper, pin: "9999")

        XCTAssertFalse(KeychainBackendPINs.carryOver(from: old, to: keeper, preferOld: true))

        XCTAssertEqual(pin(keeper), "9999")
    }

    // MARK: - Merge paths

    func test_recordDeviceIdentityMerge_movesTheNewRowsPINToTheKeeper() {
        let box = makeSandbox()
        let keeper = box.newID(), fresh = box.newID()
        let manager = BackendConnectionManager()
        manager.paired = [
            PairedBackend(id: keeper, url: urlA, name: "Mac"),
            PairedBackend(id: fresh, url: urlB, name: "Backend"),
        ]
        manager.activeBackendID = fresh
        KeychainBackendPINs.write(backendID: fresh, pin: "2468")

        manager.recordDeviceIdentity(DeviceIdentityMessage(deviceID: keeper, deviceKind: "mac",
                                                           displayName: "Mac"))

        XCTAssertEqual(manager.paired.map(\.id), [keeper], "the two rows for one Mac merged")
        XCTAssertEqual(pin(keeper), "2468", "the keeper had no PIN; it gets the one just typed")
        XCTAssertNil(pin(fresh))
    }

    func test_perSessionIdentityMerge_movesTheNewRowsPINToTheKeeper() throws {
        let box = makeSandbox()
        let keeper = box.newID()
        let manager = BackendConnectionManager()
        manager.paired = [PairedBackend(id: keeper, url: urlA, name: "Mac")]
        manager.ensureImplicitDefault(url: urlB)          // the Bonjour tap's temporary row
        let freshID = box.track(manager.activeBackendID)
        let fresh = try XCTUnwrap(manager.sessions[freshID])
        KeychainBackendPINs.write(backendID: freshID, pin: "1357")
        KeychainBackendPINs.write(backendID: keeper, pin: "0000")   // an old PIN

        try deliverIdentity(keeper, to: fresh)

        XCTAssertEqual(manager.paired.map(\.id), [keeper])
        XCTAssertEqual(manager.activeBackendID, keeper)
        XCTAssertEqual(pin(keeper), "1357", "the PIN that just authenticated replaces the old one")
        XCTAssertNil(pin(freshID))
    }

    func test_reap_fillsACanonicalRowWithoutPIN() {
        let box = makeSandbox()
        let canonical = box.newID(), duplicate = box.newID()
        let manager = BackendConnectionManager()
        manager.paired = [
            PairedBackend(id: canonical, url: urlA, name: "Mac", lastSeenLayoutMonitorName: "Display"),
            PairedBackend(id: duplicate, url: urlB, name: "Mac", lastSeenLayoutMonitorName: "Display"),
        ]
        KeychainBackendPINs.write(backendID: duplicate, pin: "1111")

        manager.reapDuplicateSameMac(canonicalID: canonical, knownLocalURLs: [urlB])

        XCTAssertEqual(manager.paired.map(\.id), [canonical])
        XCTAssertEqual(pin(canonical), "1111")
        XCTAssertNil(pin(duplicate))
    }

    func test_reap_neverReplacesTheCanonicalRowsPIN() {
        let box = makeSandbox()
        let canonical = box.newID(), duplicate = box.newID()
        let manager = BackendConnectionManager()
        manager.paired = [
            PairedBackend(id: canonical, url: urlA, name: "Mac", lastSeenLayoutMonitorName: "Display"),
            PairedBackend(id: duplicate, url: urlB, name: "Mac", lastSeenLayoutMonitorName: "Display"),
        ]
        KeychainBackendPINs.write(backendID: canonical, pin: "2222")
        KeychainBackendPINs.write(backendID: duplicate, pin: "1111")

        manager.reapDuplicateSameMac(canonicalID: canonical, knownLocalURLs: [urlB])

        XCTAssertEqual(pin(canonical), "2222", "a stale duplicate never overwrites the working PIN")
        XCTAssertNil(pin(duplicate))
    }

    // MARK: - Auth success that the host handles after the merge

    func test_successHandledAfterMerge_persistsThePINForTheSurvivingRow() throws {
        let box = makeSandbox()
        let keeper = box.newID()
        let manager = BackendConnectionManager()
        manager.paired = [PairedBackend(id: keeper, url: urlA, name: "Mac")]
        manager.ensureImplicitDefault(url: urlB)
        let freshID = box.track(manager.activeBackendID)
        let fresh = try XCTUnwrap(manager.sessions[freshID])

        // device_identity merges the rows before the host's deferred
        // auth-success block runs; that block then saves the PIN it read.
        try deliverIdentity(keeper, to: fresh)
        manager.persistValidatedPIN("8642", for: fresh)

        XCTAssertEqual(pin(keeper), "8642")
        XCTAssertNil(pin(freshID), "nothing is written under the merged-away id")
    }

    func test_successHandledAfterRekey_persistsThePINForTheRekeyedRow() throws {
        let box = makeSandbox()
        let manager = BackendConnectionManager()
        manager.ensureImplicitDefault(url: urlB)
        let legacyID = box.track(manager.activeBackendID)
        let session = try XCTUnwrap(manager.sessions[legacyID])
        let realID = box.newID()

        try deliverIdentity(realID, to: session)
        manager.persistValidatedPIN("8642", for: session)

        XCTAssertEqual(manager.paired.map(\.id), [realID])
        XCTAssertEqual(pin(realID), "8642")
        XCTAssertNil(pin(legacyID))
    }

    func test_persistValidatedPIN_forAForgottenRow_writesNothing() throws {
        let box = makeSandbox()
        let manager = BackendConnectionManager()
        manager.ensureImplicitDefault(url: urlB)
        let id = box.track(manager.activeBackendID)
        let session = try XCTUnwrap(manager.sessions[id])
        manager.forget(id)

        manager.persistValidatedPIN("8642", for: session)

        XCTAssertNil(pin(id))
        XCTAssertNil(manager.survivingBackendID(for: id))
    }

    // MARK: - Load-time and restore-time dedup

    func test_survivorsOfDroppedRows_mapsEachDroppedIdToTheRowThatAbsorbedIt() {
        let before = [
            PairedBackend(id: "real", url: urlA, name: "Mac"),
            PairedBackend(id: "legacy", url: urlA, name: "Backend", fallbackURLs: [urlB]),
            PairedBackend(id: "other", url: "ws://10.9.9.9:8765", name: "Other"),
        ]
        let after = BackendConnectionManager.mergeSameIDRows(before)

        XCTAssertEqual(BackendConnectionManager.survivors(ofRowsDroppedFrom: before, into: after),
                       ["legacy": "real"])
    }

    func test_restoreMerge_handsADroppedRowsPINToARowWithoutOne() throws {
        let box = makeSandbox()
        let live = box.newID(), restored = box.newID()
        let manager = BackendConnectionManager()
        // Disabled rows, so the sessions the restore spawns never dial.
        manager.paired = [PairedBackend(id: live, url: urlA, name: "Mac", enabled: false)]
        manager.activeBackendID = live
        KeychainBackendPINs.write(backendID: restored, pin: "5555")
        let json = String(decoding: try JSONEncoder().encode([
            PairedBackend(id: restored, url: urlA, name: "Mac", enabled: false),
        ]), as: UTF8.self)

        manager.mergeRestoredBackends(json, activeID: nil)

        XCTAssertEqual(manager.paired.map(\.id), [live])
        XCTAssertEqual(pin(live), "5555")
        XCTAssertNil(pin(restored))
    }
}
