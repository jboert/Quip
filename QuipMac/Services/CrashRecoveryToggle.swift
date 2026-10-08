// CrashRecoveryToggle.swift
// QuipMac — What the "Auto-restart on crash" toggle settles on

import Foundation

/// Decides the Reliability toggle's stored value after the user flips it.
/// `apply` installs (true) or removes (false) the crash-recovery LaunchAgent;
/// when it throws, the toggle reverts and the error is shown inline so the
/// user sees why launchd refused (typically: SIP-protected path, missing
/// LaunchAgents directory permissions, or a malformed plist payload).
enum CrashRecoveryToggle {
    static func resolve(requested: Bool, apply: (Bool) throws -> Void) -> (enabled: Bool, error: String?) {
        do {
            try apply(requested)
            return (requested, nil)
        } catch {
            return (!requested, "Could not \(requested ? "install" : "remove") crash-recovery agent: \(error.localizedDescription)")
        }
    }
}
