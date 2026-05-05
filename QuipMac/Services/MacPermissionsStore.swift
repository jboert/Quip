import Foundation

/// Shared observable holder for the latest TCC permission snapshot Mac-side.
/// Lets the MenuBarExtra icon and the in-menu Permissions section read the
/// same probe results that get broadcast over the WebSocket. Mirrors the
/// shape of `WhisperStatusStore` for consistency.
@Observable
@MainActor
final class MacPermissionsStore {
    var snapshot: MacPermissionsMessage?

    var deniedCount: Int { snapshot?.deniedCount ?? 0 }
    var anyDenied: Bool { deniedCount > 0 }
}
