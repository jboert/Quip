// PermissionProbeService.swift
// QuipMac — probe the three TCC permissions Quip needs and report status to
// connected iPhone clients. Lets the phone surface red/green dots without the
// user having to dig through System Settings to check.

import Foundation
import ApplicationServices
import CoreGraphics

@MainActor
final class PermissionProbeService {

    /// iTerm's bundle ID — what we probe for Apple Events permission. Quip
    /// primarily drives iTerm; Terminal.app support is incidental, so we don't
    /// probe both. If a user is iTerm-less, the false-positive is preferable
    /// to a confusing red dot.
    static let iTermBundleID = "com.googlecode.iterm2"

    func probe() -> MacPermissionsMessage {
        MacPermissionsMessage(
            accessibility: AXIsProcessTrusted(),
            appleEvents: probeAppleEventsForITerm(),
            screenRecording: CGPreflightScreenCaptureAccess()
        )
    }

    /// Returns false ONLY when the user has explicitly denied Apple Events for
    /// the target. `procNotFound` (target not running) is treated as granted —
    /// we can't tell, and the alternative is permanent red until iTerm launches.
    private func probeAppleEventsForITerm() -> Bool {
        guard let bundleData = Self.iTermBundleID.data(using: .utf8) else { return true }

        var addressDesc = AEAddressDesc()
        let createStatus: OSStatus = bundleData.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return OSStatus(Int(errAEWrongDataType)) }
            return OSStatus(AECreateDesc(typeApplicationBundleID, base, bundleData.count, &addressDesc))
        }
        guard createStatus == noErr else { return true }
        defer { AEDisposeDesc(&addressDesc) }

        let result = AEDeterminePermissionToAutomateTarget(
            &addressDesc,
            typeWildCard,
            typeWildCard,
            false  // askUserIfNeeded — silent probe
        )
        switch result {
        case noErr: return true
        case OSStatus(procNotFound): return true
        case OSStatus(errAEEventNotPermitted): return false
        default: return true
        }
    }
}
