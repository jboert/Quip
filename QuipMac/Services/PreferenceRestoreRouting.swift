// PreferenceRestoreRouting.swift
// QuipMac — which `preferences_restore` answers a `preferences_request`

import Foundation

/// The reply to one phone's `preferences_request`.
///
/// Pure, so the routing is unit-testable without a socket. The reply is
/// addressed to the device that asked (`deviceID`), and its body is that
/// device's own saved snapshot — or defaults when none is saved or the saved
/// one will not decode. The caller sends it through
/// `WebSocketServer.sendToClient(_:connection:)` to the connection the request
/// arrived on, never through `broadcast`: a broadcast reached every connected
/// phone, so whenever any device authenticated, every other device had its
/// quick buttons, colors and text size replaced by the newcomer's (US-014).
enum PreferenceRestoreRouting {

    /// What the lookup found. Surfaced so the caller can keep logging the two
    /// non-restore cases differently: "no backup" is ordinary on a fresh
    /// pairing, "won't decode" means the phone is about to be handed defaults
    /// over real settings and someone should know.
    enum Outcome: Equatable, Sendable {
        case restored
        case noBackup
        case undecodable(bytes: Int, error: String)
    }

    struct Reply: Sendable {
        let message: PreferenceRestoreMessage
        let outcome: Outcome
    }

    /// `blob` is whatever UserDefaults holds under the requesting device's
    /// prefs key, or nil when nothing is saved.
    static func reply(for deviceID: String, blob: Data?) -> Reply {
        guard let blob else {
            return Reply(message: PreferenceRestoreMessage(deviceID: deviceID,
                                                           preferences: PreferencesSnapshot()),
                         outcome: .noBackup)
        }
        do {
            let snapshot = try JSONDecoder().decode(PreferencesSnapshot.self, from: blob)
            return Reply(message: PreferenceRestoreMessage(deviceID: deviceID, preferences: snapshot),
                         outcome: .restored)
        } catch {
            return Reply(message: PreferenceRestoreMessage(deviceID: deviceID,
                                                           preferences: PreferencesSnapshot()),
                         outcome: .undecodable(bytes: blob.count, error: "\(error)"))
        }
    }
}
