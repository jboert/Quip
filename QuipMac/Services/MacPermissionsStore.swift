import Foundation

/// Shared observable holder for the latest TCC permission snapshot Mac-side.
/// Lets the MenuBarExtra icon and the in-menu Permissions section read the
/// same probe results that get broadcast over the WebSocket. Mirrors the
/// shape of `WhisperStatusStore` for consistency.
@Observable
@MainActor
final class MacPermissionsStore {
    var snapshot: MacPermissionsMessage?

    /// Quiet "you should re-grant on your terms" signal, distinct from the live
    /// `anyDenied`. Raised (US-002, GH #33) when the launch path detects the app
    /// was just rebuilt — cdhash changed since last launch, see `CodeIdentity` —
    /// AND a permission preflights false, OR when a grant is dropped mid-session
    /// (denied count rises on a probe). It NEVER force-opens System Settings; it
    /// drives the menubar warning glyph + a 'Fix Permissions…' affordance
    /// (US-003) so the user acts when they choose. Auto-clears once a probe shows
    /// every permission granted again, so the glyph can't get stuck lit.
    var permissionsNeedAttention: Bool = false

    var deniedCount: Int { snapshot?.deniedCount ?? 0 }
    var anyDenied: Bool { deniedCount > 0 }
}
