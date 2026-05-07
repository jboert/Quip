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

    var windows: [WindowState] = []
    var selectedWindowId: String?
    var monitorName: String = "Mac"
    var screenAspect: Double = 16.0 / 10.0
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
    var qaPair: QAPair?

    init(backendID: String, client: WebSocketClient) {
        self.backendID = backendID
        self.client = client
        // Hydrate persisted QA pair if present.
        if let blob = UserDefaults.standard.data(forKey: "qaPair.\(backendID)"),
           let pair = try? JSONDecoder().decode(QAPair.self, from: blob) {
            self.qaPair = pair
        }
    }

    /// Mutate `qaPair` and write through to UserDefaults. Use this from the
    /// host instead of assigning `qaPair` directly so persistence always
    /// lines up with the in-memory value.
    func updateQAPair(_ pair: QAPair?) {
        self.qaPair = pair
        let key = "qaPair.\(backendID)"
        if let pair, let blob = try? JSONEncoder().encode(pair) {
            UserDefaults.standard.set(blob, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
