import Foundation

/// Phone-side classification helpers on `WindowState`. These mirror the
/// Mac-side `ManagedWindow.isTerminal` / `isTarget` predicates without
/// requiring `bundleId` on the wire. The Mac is the authoritative source
/// for `targetKind`; phone-side `isTarget` just reads it back.
extension WindowState {
    /// True when this window is eligible as the QA-mode "target" half.
    /// Mac populates `targetKind` to `"simulator"` (v1), `"browser_localhost"` (v2),
    /// or nil. Phone treats any non-nil value as eligible.
    var isTarget: Bool { targetKind != nil }

    /// True when this window is hosted by a known terminal emulator. Mirrors
    /// `ManagedWindow.isTerminal` on the Mac (which compares against
    /// `TerminalApp.terminal.bundleIdentifier` / `TerminalApp.iterm2.bundleIdentifier`).
    /// The wire format doesn't carry `bundleId`, so we match on `app` against
    /// the exact strings the Mac populates.
    ///
    /// IMPORTANT: keep this list in sync with the Mac-side `TerminalApp`
    /// enum — adding a new terminal emulator on the Mac requires updating
    /// this set or QA-mode pairing will silently exclude that emulator.
    var isTerminal: Bool {
        // Compare case-insensitively to absorb minor casing drift on the Mac
        // side (e.g. "iTerm2" vs "iterm2"). Exact-equality on a small set —
        // no substring matching, since folder names surfaced as `app` could
        // false-positive (e.g. "iterm-tools" project folder).
        let lower = app.lowercased()
        return lower == "iterm2" || lower == "terminal"
    }
}
