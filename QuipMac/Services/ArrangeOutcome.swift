// ArrangeOutcome.swift
// QuipMac — Why an Arrange did (or did not) move anything

import Foundation

/// The one verdict both Arrange buttons — the main window's toolbar and the
/// menu-bar panel — report from. The menu-bar button used to bail on a missing
/// display and ignore a revoked Accessibility grant, so it silently did nothing.
enum ArrangeOutcome: Equatable {
    case arranged, noWindows, noDisplay, accessibilityDenied

    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// `arranged` performs the move and returns false when Accessibility
    /// refused it. It is only called once there is something to arrange and
    /// somewhere to put it.
    static func evaluate(enabledCount: Int, hasDisplay: Bool, arranged: () -> Bool) -> ArrangeOutcome {
        guard enabledCount > 0 else { return .noWindows }
        guard hasDisplay else { return .noDisplay }
        return arranged() ? .arranged : .accessibilityDenied
    }

    var message: String? {
        switch self {
        case .arranged:
            return nil
        case .noWindows:
            return "No windows are enabled — tick one in the Quip window's sidebar first."
        case .noDisplay:
            return "No display available to arrange on."
        case .accessibilityDenied:
            return "Quip needs Accessibility access to move windows. Grant it in System Settings → Privacy & Security → Accessibility."
        }
    }
}
