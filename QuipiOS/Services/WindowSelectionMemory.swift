import Foundation

/// Remembers which window the user last had selected, per backend, so a
/// reconnect lands back on it. Backgrounding the app suspends the socket; the
/// reconnect on return clears `selectedWindowId`, and the first layout_update
/// used to auto-pick `windows.first` — a different terminal than the one the
/// user was typing in. Window ids (bundle id + window number) are stable while
/// the Mac window stays open, so the remembered id is still valid after a
/// reconnect; when the window has closed meanwhile, fall back to the first.
enum WindowSelectionMemory {
    static func key(forBackendId backendId: String) -> String {
        "lastSelectedWindow.\(backendId)"
    }

    /// The window to select when nothing is selected yet.
    static func initialSelection(remembered: String?, available: [String]) -> String? {
        if let remembered, available.contains(remembered) { return remembered }
        return available.first
    }

    static func remembered(forBackendId backendId: String,
                           defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key(forBackendId: backendId))
    }

    static func remember(_ windowId: String, forBackendId backendId: String,
                         defaults: UserDefaults = .standard) {
        defaults.set(windowId, forKey: key(forBackendId: backendId))
    }
}
