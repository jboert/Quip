import Foundation
import Observation

/// The "Show Claude's previews on phone" switch (Q-87): one place that reads
/// and changes the hook's install state, used by the Mac Settings row and by
/// the phone's `set_claude_previews`.
@MainActor
@Observable
final class ClaudeHookSwitch {
    private(set) var status: ClaudeHookInstaller.Status = .off
    /// The last install/uninstall failure, in words for the Settings row.
    private(set) var lastError: String?

    /// Called after any change, so phones can be told.
    @ObservationIgnored var onChange: (() -> Void)?

    /// The helper inside this copy of Quip; nil in a build without it.
    static var bundledHookPath: String? {
        Bundle.main.url(forAuxiliaryExecutable: "quip-claude-hook")?.path
    }

    var isOn: Bool {
        switch status {
        case .on, .stale: return true
        case .off, .unreadable: return false
        }
    }

    /// The value the phone shows, `MacPermissionsMessage.claudePreviews`.
    var wireValue: String {
        switch status {
        case .off: return "off"
        case .on: return "on"
        case .stale: return "stale"
        case .unreadable: return "unreadable"
        }
    }

    /// Set once someone turns the switch off, so Quip never turns it back on.
    static let userTurnedOffKey = "claudePreviews.userTurnedOff"

    /// On by default: at launch, a Quip installed in an Applications folder on
    /// a Mac with Claude Code adds its hook (or re-points one left by a Quip
    /// that moved), unless someone turned the switch off. Debug builds and
    /// test hosts run from elsewhere and never touch the settings file.
    func applyDefault(defaults: UserDefaults = .standard) {
        refresh()
        let claudeInstalled = FileManager.default.fileExists(
            atPath: ClaudeHookInstaller.settingsURL.deletingLastPathComponent().path)
        guard Self.shouldAutoInstall(status: status,
                                     userTurnedOff: defaults.bool(forKey: Self.userTurnedOffKey),
                                     claudeInstalled: claudeInstalled,
                                     appPath: Bundle.main.bundlePath) else { return }
        set(true, source: "auto", defaults: defaults)
    }

    nonisolated static func shouldAutoInstall(status: ClaudeHookInstaller.Status, userTurnedOff: Bool,
                                              claudeInstalled: Bool, appPath: String) -> Bool {
        guard !userTurnedOff, claudeInstalled, appPath.contains("/Applications/") else { return false }
        switch status {
        case .off, .stale: return true
        case .on, .unreadable: return false
        }
    }

    func refresh() {
        guard let path = Self.bundledHookPath else { status = .off; return }
        status = ClaudeHookInstaller.statusOnDisk(hookPath: path)
    }

    /// Turns the hook on or off. `.stale` + on = Repair (re-points the path).
    func set(_ on: Bool, source: String, defaults: UserDefaults = .standard) {
        lastError = nil
        if source != "auto" { defaults.set(!on, forKey: Self.userTurnedOffKey) }
        do {
            if on {
                guard let path = Self.bundledHookPath else {
                    lastError = "This copy of Quip has no quip-claude-hook helper."
                    log(.error, "INSTALL source=\(source) result=no-helper")
                    return
                }
                try ClaudeHookInstaller.installOnDisk(hookPath: path)
            } else {
                try ClaudeHookInstaller.uninstallOnDisk()
            }
            log(.info, "\(on ? "INSTALL" : "UNINSTALL") source=\(source) result=ok")
        } catch ClaudeHookInstaller.InstallError.unreadable {
            lastError = "Claude's settings file isn't valid JSON — not touched."
            log(.error, "\(on ? "INSTALL" : "UNINSTALL") source=\(source) result=unreadable")
        } catch {
            lastError = "Couldn't update Claude's settings: \(error.localizedDescription)"
            log(.error, "\(on ? "INSTALL" : "UNINSTALL") source=\(source) result=\(error)")
        }
        refresh()
        onChange?()
    }

    private func log(_ severity: QuipLog.Severity, _ message: String) {
        QuipLog.write(severity: severity, subsystem: "claude-previews", message: message,
                      to: LogPaths.claudePreviewsPath)
    }
}
