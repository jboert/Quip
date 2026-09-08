import Foundation

/// Per-backend state slice. Each paired backend has one of these living inside
/// `BackendConnectionManager.sessions`. Switching active backend is just a
/// pointer flip on `BackendConnectionManager.activeBackendID` — no I/O, since
/// background sessions stay live (Hot model) and accumulate state in their own
/// slice.
///
/// Side-effect-y callbacks (toasts, sheets, TTS playback, Live Activity) check
/// `id == manager.activeBackendID` before firing user-visible effects but
/// always update the slice, so a switch shows fresh data immediately.
@MainActor
@Observable
final class BackendSession {
    enum Reachability {
        case connecting
        case connected
        case unreachable
        case needsAuth
    }

    let backendID: String
    let client: WebSocketClient

    /// UserDefaults key for the persisted QA pair. Computed from `backendID`.
    /// Centralized so init + `updateQAPair` can't drift.
    private var qaPairUserDefaultsKey: String { "qaPair.\(backendID)" }

    /// Per-backend UserDefaults key for the QA-mode pane position-swap flag.
    /// Namespaced like `qaPair.swapped.<backendId>` so two backends paired
    /// in QA mode keep independent left/right orderings.
    static func swapKey(forBackendId backendId: String) -> String {
        "qaPair.swapped.\(backendId)"
    }

    /// Per-backend persistence for the screen chip selection. Namespaced by
    /// backend id for the same reason as the QA-pair keys: two Macs have
    /// different monitors, and one's choice must not leak into the other's.
    static func screenFilterKey(forBackendId backendId: String) -> String {
        "screenFilter.\(backendId)"
    }

    var windows: [WindowState] = []
    var selectedWindowId: String?
    var monitorName: String = "Mac"
    var screenAspect: Double = 16.0 / 10.0
    /// Every display connected to this Mac, newest `layout_update` wins.
    /// Empty for a single-screen Mac or an older Mac build that doesn't send
    /// the list — the screen chips hide themselves in both cases.
    var displays: [DisplayState] = []
    /// width / height of all displays combined, for the "All screens" canvas.
    var spanAspect: Double = 16.0 / 10.0
    /// Which screen's windows to show. nil = all screens. Persisted per
    /// backend (`screenFilterKey`) so "the terminal screen" survives an app
    /// relaunch — keyed by CGDirectDisplayID, so it can't drift onto the wrong
    /// monitor when displays are reordered.
    var selectedDisplayID: String?
    var terminalContentText: String?
    var terminalContentScreenshot: String?
    var terminalContentURLs: [String]?
    var terminalContentWindowId: String?
    var projectDirectories: [String] = []
    var iTermScanResults: [ITermWindowInfo]?
    var macPermissions: MacPermissionsMessage?
    /// Output delta text per window — TTS overlay captions for the active session.
    var ttsOverlayTexts: [String: String] = [:]
    var reachability: Reachability = .connecting

    /// QA mode pair for this backend. nil = not in QA mode. Persisted to
    /// `UserDefaults` under "qaPair.\(backendID)" as JSON-encoded `QAPair`.
    /// Use `updateQAPair(_:)` to mutate so persistence stays in sync.
    private(set) var qaPair: QAPair?

    init(backendID: String, client: WebSocketClient) {
        self.backendID = backendID
        self.client = client
        // Hydrate persisted QA pair if present.
        if let blob = UserDefaults.standard.data(forKey: qaPairUserDefaultsKey),
           let pair = try? JSONDecoder().decode(QAPair.self, from: blob) {
            self.qaPair = pair
        }
        // Hydrate the screen chip selection. Validated against the live
        // display list on the first layout_update — an unplugged monitor's id
        // is dropped there, not here (no display list exists yet at init).
        self.selectedDisplayID = UserDefaults.standard.string(
            forKey: Self.screenFilterKey(forBackendId: backendID))
    }

    /// Mutate `selectedDisplayID` and write through to UserDefaults, so the
    /// chosen screen survives a relaunch. nil means "all screens".
    func updateSelectedDisplay(_ id: String?) {
        self.selectedDisplayID = id
        let key = Self.screenFilterKey(forBackendId: backendID)
        if let id {
            UserDefaults.standard.set(id, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Mutate `qaPair` and write through to UserDefaults. Use this from the
    /// host instead of assigning `qaPair` directly so persistence always
    /// lines up with the in-memory value.
    func updateQAPair(_ pair: QAPair?) {
        self.qaPair = pair
        if let pair, let blob = try? JSONEncoder().encode(pair) {
            UserDefaults.standard.set(blob, forKey: qaPairUserDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: qaPairUserDefaultsKey)
        }
    }
}
