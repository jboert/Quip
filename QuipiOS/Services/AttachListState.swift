import Foundation

/// Which rows of the Attach Existing list read as attached.
///
/// The Mac's scan reports `isAlreadyTracked` only for windows whose iTerm2
/// session id is already mapped, which lags an attach by several seconds. The
/// phone remembers the session ids it attached itself until a scan agrees, so
/// a row tapped a moment ago already reads "Attached" when the sheet reopens.
enum AttachListState {
    static func isAttached(_ info: ITermWindowInfo, recent: Set<String>) -> Bool {
        info.isAlreadyTracked || recent.contains(info.sessionId)
    }

    /// Forgets ids the Mac now reports as tracked (it has caught up) and ids
    /// the scan no longer lists (the window closed), so no row stays
    /// "Attached" for a window that is gone.
    static func pruned(_ recent: Set<String>, afterScan windows: [ITermWindowInfo]) -> Set<String> {
        let listed = Set(windows.map(\.sessionId))
        let tracked = Set(windows.filter(\.isAlreadyTracked).map(\.sessionId))
        return recent.filter { listed.contains($0) && !tracked.contains($0) }
    }
}
