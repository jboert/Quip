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

    init(backendID: String, client: WebSocketClient) {
        self.backendID = backendID
        self.client = client
    }
}
