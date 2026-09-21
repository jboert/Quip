import Foundation
import UIKit
import UserNotifications
import Observation

/// Owns the APNs device-token lifecycle on iOS: permission prompt, token
/// capture, hex encoding, @AppStorage persistence, and handing it off to
/// the Mac over the existing WebSocket via `RegisterPushDeviceMessage`.
///
/// Intentionally decoupled from WebSocketClient — the caller (QuipApp) is
/// responsible for invoking `sendTokenIfAvailable` after auth succeeds.
/// That lets us re-send the cached token on every reconnect without this
/// service needing to know about connection state.
@MainActor
@Observable
final class PushRegistrationService {
    /// Last-known device token as an uppercase hex string, or nil if we
    /// haven't registered yet (or the user declined permission).
    private(set) var deviceToken: String? {
        didSet { UserDefaults.standard.set(deviceToken, forKey: Self.tokenKey) }
    }

    /// "development" matches the aps-environment entitlement; if the app
    /// is ever signed with a production distribution profile, this flips
    /// at build time via a compile-time flag. For now eb-branch is always
    /// dev — no production builds exist yet.
    var environment: String { "development" }

    private static let tokenKey = "apnsDeviceToken"

    /// A cached APNs token is not proof that alerts can still be shown: the
    /// user can disable notifications in Settings after registration.
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    var canPresentAlerts: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        case .notDetermined, .denied: false
        @unknown default: false
        }
    }

    init() {
        deviceToken = UserDefaults.standard.string(forKey: Self.tokenKey)
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    /// Called from the app delegate when APNs hands us a fresh token.
    /// Encodes the raw bytes as uppercase hex (APNs convention) and
    /// stores via @AppStorage so we don't lose it across launches.
    func registerDeviceToken(_ tokenData: Data) {
        let hex = tokenData.map { String(format: "%02X", $0) }.joined()
        if hex != deviceToken {
            print("[PushRegistration] received new device token (prefix=\(hex.prefix(8)))")
            deviceToken = hex
        }
    }

    /// Called from the app delegate when registration fails. We log and
    /// leave the cached token alone — a failure here usually means the
    /// device is offline or in Airplane Mode, and the cached token from
    /// a prior successful registration is still valid.
    func registrationFailed(_ error: Error) {
        print("[PushRegistration] registration failed: \(error.localizedDescription)")
    }

    /// Ask the user for notification permission the first time, then
    /// register for remote notifications on grant. Safe to call many
    /// times — UNUserNotificationCenter only prompts the user once per
    /// install lifetime; subsequent calls return the cached answer.
    ///
    /// On denial we don't prompt again this session; the user can enable
    /// via iOS Settings → Quip → Notifications. A future Settings row in
    /// Quip itself could deep-link there.
    func requestPermissionAndRegister() async {
        let center = UNUserNotificationCenter.current()
        do {
            authorizationStatus = await center.notificationSettings().authorizationStatus
            if canPresentAlerts {
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } else if authorizationStatus == .notDetermined {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                await refreshAuthorizationStatus()
                if granted && canPresentAlerts {
                    await MainActor.run {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
            } else {
                print("[PushRegistration] notification permission is disabled")
            }
        } catch {
            print("[PushRegistration] requestAuthorization error: \(error.localizedDescription)")
        }
    }
}
