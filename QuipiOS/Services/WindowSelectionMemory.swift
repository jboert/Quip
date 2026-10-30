import Foundation

/// Remembers which window the user last had selected, per backend, so a
/// reconnect lands back on it. Backgrounding the app suspends the socket; the
/// reconnect on return clears `selectedWindowId`, and the first layout_update
/// used to auto-pick `windows.first` — a different terminal than the one the
/// user was typing in. Window ids (bundle id + window number) are stable while
/// the Mac window stays open, so the remembered id is still valid after a
/// reconnect; when the window has closed meanwhile, fall back to the first.
///
/// Q-88 keeps the windows before it too, most recent first (at most `cap`), so
/// when the last window has closed the phone lands on the one the user was in
/// before it rather than on `windows.first`. The list lives under the same key;
/// a single id stored by an earlier build reads as a list of one.
enum WindowSelectionMemory {
    static let cap = 20

    static func key(forBackendId backendId: String) -> String {
        "lastSelectedWindow.\(backendId)"
    }

    /// The window to select when nothing is selected yet.
    static func initialSelection(remembered: String?, available: [String]) -> String? {
        if let remembered, available.contains(remembered) { return remembered }
        return available.first
    }

    /// The window to select when nothing is selected yet: the most recent one
    /// still open, else the first.
    static func initialSelection(recent: [String], available: [String]) -> String? {
        best(recent: recent, available: available) ?? available.first
    }

    /// The most recent window that is in `available` and is not `excluding`.
    static func best(recent: [String], available: [String], excluding: String? = nil) -> String? {
        let open = Set(available)
        return recent.first { open.contains($0) && $0 != excluding }
    }

    /// `recent` with `windowId` moved to the top, without duplicates, at most `cap`.
    static func touched(_ recent: [String], with windowId: String) -> [String] {
        Array(([windowId] + recent.filter { $0 != windowId }).prefix(cap))
    }

    /// `recent` without the windows that are not in `available`, order kept.
    static func pruned(_ recent: [String], keeping available: Set<String>) -> [String] {
        recent.filter { available.contains($0) }
    }

    static func remembered(forBackendId backendId: String,
                           defaults: UserDefaults = .standard) -> String? {
        recent(forBackendId: backendId, defaults: defaults).first
    }

    /// Most recent first. Duplicates and anything past `cap` are dropped.
    static func recent(forBackendId backendId: String,
                       defaults: UserDefaults = .standard) -> [String] {
        let key = key(forBackendId: backendId)
        let stored = defaults.stringArray(forKey: key) ?? defaults.string(forKey: key).map { [$0] } ?? []
        var seen = Set<String>()
        return Array(stored.filter { seen.insert($0).inserted }.prefix(cap))
    }

    static func remember(_ windowId: String, forBackendId backendId: String,
                         defaults: UserDefaults = .standard) {
        let recent = touched(recent(forBackendId: backendId, defaults: defaults), with: windowId)
        defaults.set(recent, forKey: key(forBackendId: backendId))
    }
}
