import Foundation
import Security

/// Per-backend PIN storage, keyed by the daemon's stable device UUID
/// (`DeviceIdentityMessage.deviceID`). Mirrors `KeychainDeviceID`'s pattern
/// but partitions by `account = backendID` so multiple paired backends each
/// get their own PIN.
///
/// `kSecAttrAccessibleAfterFirstUnlock` is required: `BackendConnectionManager`
/// auto-connects every paired backend at app launch and after backgrounding,
/// which can happen before the user interacts with the app — the Keychain
/// needs to be readable in those moments.
enum KeychainBackendPINs {
    private static let service = "com.quip.QuipiOS.backend-pin"

    /// Under XCTest the store is a dictionary, as APNsKeyStore does on the
    /// Mac. CI builds the test host unsigned (CODE_SIGNING_ALLOWED=NO), and
    /// an unsigned host has no Keychain entitlement: every SecItem call
    /// answers -34018 and the carry-over tests read nil. What those tests
    /// check is the carry-over logic, not SecItem.
    private static var testBacking: [String: String] = [:]
    private static var useTestBacking: Bool { TestHostGuard.isRunningTests }

    /// `read` runs on every connect attempt, per backend (up to 4):
    /// `BackendConnectionManager.connect()`, `onAuthRequired`, and
    /// `primePINIfPresent` all re-enter it after every reconnect. Its failure
    /// causes are PERSISTENT — a keychain that's still locked (-25308, the
    /// documented auto-connect-before-first-unlock case) stays locked — so an
    /// unlatched log would print on every attempt, forever.
    ///
    /// Keyed per backend so a broken backend A can't mask backend B's first
    /// failure, and per status so a CHANGED status is re-reported.
    static let readLatch = KeyedLogLatch()

    /// Decide what (if anything) to log for a Keychain status. Split out from
    /// `read` so tests can drive the statuses that are impossible to provoke
    /// against a real Keychain (-25308 / -34018). Returns nil when this status
    /// is ordinary, or already latched.
    static func failureLine(status: OSStatus,
                            backendID: String,
                            latch: KeyedLogLatch = readLatch) -> String? {
        // `errSecItemNotFound` is ORDINARY — this backend simply has no PIN
        // saved. Every other non-success status is a real failure that we used
        // to collapse into the same `nil`, so the caller
        // (`primePINIfPresent`) quietly skipped auth and the phone sat there
        // "connected but not authenticated" with nothing to explain it.
        // -25308 errSecInteractionNotAllowed (keychain still locked) and
        // -34018 errSecMissingEntitlement (access group lost across a resign)
        // are the two that actually bite.
        guard status != errSecSuccess, status != errSecItemNotFound else {
            latch.noteSuccess(for: backendID)
            return nil
        }
        let v = latch.verdict(for: backendID, cause: "OSStatus=\(status)")
        guard v.shouldLog else { return nil }
        return "[Quip][Keychain] PIN read FAILED backend=\(backendID) OSStatus=\(status) — auth will be skipped for this backend" + v.suffix
    }

    static func read(backendID: String, log: (String) -> Void = { print($0) }) -> String? {
        if useTestBacking { return testBacking[backendID] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: backendID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if let line = failureLine(status: status, backendID: backendID, latch: readLatch) {
            log(line)
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    static func write(backendID: String, pin: String) {
        if useTestBacking { testBacking[backendID] = pin; return }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: backendID,
            kSecValueData as String: Data(pin.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(attrs as CFDictionary)
        _ = SecItemAdd(attrs as CFDictionary, nil)
    }

    static func delete(backendID: String) {
        if useTestBacking { testBacking[backendID] = nil; return }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: backendID,
        ]
        SecItemDelete(attrs as CFDictionary)
    }

    /// Used when the daemon's `device_identity` arrives after the entry was
    /// created with a synthetic id — copy the PIN under the real UUID and drop
    /// the synthetic one.
    static func rekey(from oldID: String, to newID: String) {
        guard oldID != newID, let pin = read(backendID: oldID) else { return }
        write(backendID: newID, pin: pin)
        delete(backendID: oldID)
    }

    /// Move the PIN of a row that is being merged away onto the row that
    /// survives the merge (`keeperID`), then drop the old entry. The merge
    /// and reap paths in `BackendConnectionManager` used to delete the old
    /// row's PIN outright, so when the survivor had none (or an old one) the
    /// PIN the user had just typed was lost and the next launch asked for it
    /// again (PRD 2026-10-07, US-005).
    ///
    /// `preferOld: true` — the old row's PIN replaces the keeper's: a merge
    /// triggered by a fresh pairing, where the old row holds the PIN that was
    /// just typed. `preferOld: false` — the keeper's PIN stands and the old
    /// one only fills a gap: a reaped stale duplicate must never overwrite a
    /// working PIN.
    ///
    /// The old entry is removed only after the keeper verifiably holds a PIN,
    /// so a Keychain that cannot be read or written at that moment (locked
    /// before first unlock, -25308) leaves both entries alone instead of
    /// turning this into a plain delete. Returns true when the keeper now
    /// holds the old row's PIN.
    @discardableResult
    static func carryOver(from oldID: String, to keeperID: String, preferOld: Bool) -> Bool {
        guard oldID != keeperID, let pin = read(backendID: oldID) else { return false }
        let moved = preferOld || read(backendID: keeperID) == nil
        if moved {
            write(backendID: keeperID, pin: pin)
        }
        guard read(backendID: keeperID) != nil else { return false }
        delete(backendID: oldID)
        return moved
    }
}
