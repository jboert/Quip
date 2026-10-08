import Foundation
import Security

/// push.log lines for the APNs Keychain items: the .p8 (`APNsKeyStore`) and the
/// Key ID / Team ID / bundle ID (`APNsMetadataStore`).
///
/// The stores used to `print` a failed SecItem call, which reaches neither
/// push.log nor the unified log from a Finder-launched app, and they said
/// nothing at all for errSecItemNotFound. So "APNs not configured" could not
/// tell an item that was never stored (or was deleted) from a Keychain that
/// refused the read.
///
/// Reads are edge-triggered: a line is written when an item's read outcome
/// changes (first absent, first error, back to ok), not on every read. Every
/// waiting_for_input event reads all three metadata fields.
enum APNsKeychainLog {

    nonisolated private static let lock = NSLock()
    /// Last read status per item; guarded by `lock`.
    nonisolated(unsafe) private static var lastReadStatus: [String: OSStatus] = [:]

    /// `absent (-25300)` for errSecItemNotFound, `failed (<status>: <message>)`
    /// for anything else that is not success.
    static func describe(_ status: OSStatus) -> String {
        switch status {
        case errSecSuccess:
            return "ok"
        case errSecItemNotFound:
            return "absent (\(status))"
        default:
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "no message"
            return "failed (\(status): \(message))"
        }
    }

    /// Pure: is this read outcome worth a line, given the last one seen for the
    /// same item? A failure is logged when it differs from the previous outcome;
    /// a success only when it ends a run of failures.
    static func shouldLogRead(previous: OSStatus?, current: OSStatus) -> Bool {
        if current == errSecSuccess {
            return previous != nil && previous != errSecSuccess
        }
        return current != previous
    }

    /// Record the outcome of a SecItemCopyMatching on `item` (the account name).
    static func noteRead(item: String, status: OSStatus) {
        lock.lock()
        let previous = lastReadStatus[item]
        lastReadStatus[item] = status
        lock.unlock()
        guard shouldLogRead(previous: previous, current: status) else { return }
        if status == errSecSuccess, let previous {
            quipPushLog("keychain read \(item): ok (was \(describe(previous)))")
        } else {
            quipPushLog("keychain read \(item): \(describe(status))")
        }
    }

    /// Record a failed write-side SecItem call (`SecItemAdd`, `SecItemDelete`).
    /// These are rare and user-initiated, so every one is logged.
    static func noteFailure(_ operation: String, item: String, status: OSStatus) {
        quipPushLog("keychain \(operation) \(item): \(describe(status))")
    }
}
