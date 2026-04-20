import Foundation

// MARK: - Message Envelope

struct WSMessage: Codable {
    let type: String
}

// MARK: - Mac → iPhone Messages

struct LayoutUpdate: Codable, Sendable {
    let type: String
    let monitor: String
    /// width / height of the host display — lets clients render a correctly-proportioned thumbnail
    let screenAspect: Double?
    let windows: [WindowState]

    init(monitor: String, screenAspect: Double? = nil, windows: [WindowState]) {
        self.type = "layout_update"
        self.monitor = monitor
        self.screenAspect = screenAspect
        self.windows = windows
    }
}

struct WindowState: Codable, Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let name: String
    let app: String
    /// Project/folder name — shown as the primary (colored, bold) label above the
    /// app name. Optional for backward compat with older Mac builds that don't
    /// populate it; clients should fall back to `app` when absent or empty.
    let folder: String?
    let enabled: Bool
    let frame: WindowFrame
    let state: String
    let color: String
    /// True when Claude/node processes are running in this window's terminal
    let isThinking: Bool
    /// Claude Code mode scraped from terminal content. One of "normal", "plan",
    /// "autoAccept", or nil if unknown / not yet detected / not a Claude window.
    /// Optional for backward compat; old Mac builds just won't populate it.
    let claudeMode: String?

    // Synthesized Equatable compares ALL fields including frame

    /// Backward-compat: default isThinking to false and claudeMode to nil if missing from JSON
    init(id: String, name: String, app: String, folder: String? = nil, enabled: Bool,
         frame: WindowFrame, state: String, color: String, isThinking: Bool = false,
         claudeMode: String? = nil) {
        self.id = id; self.name = name; self.app = app; self.folder = folder
        self.enabled = enabled
        self.frame = frame; self.state = state; self.color = color
        self.isThinking = isThinking
        self.claudeMode = claudeMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        app = try c.decode(String.self, forKey: .app)
        folder = try? c.decode(String.self, forKey: .folder)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        frame = try c.decode(WindowFrame.self, forKey: .frame)
        state = try c.decode(String.self, forKey: .state)
        color = try c.decode(String.self, forKey: .color)
        isThinking = (try? c.decode(Bool.self, forKey: .isThinking)) ?? false
        claudeMode = try? c.decode(String.self, forKey: .claudeMode)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, app, folder, enabled, frame, state, color, isThinking, claudeMode
    }
}

// MARK: - Claude Code Mode

/// Claude Code's three cyclable modes, scraped from terminal content by
/// `ClaudeModeDetector` on the Mac. Cycle order (Shift+Tab): normal → autoAccept → plan → normal.
enum ClaudeMode: String, Codable, Sendable {
    case normal
    case plan
    case autoAccept

    /// The Shift+Tab cycle order Claude Code uses internally. Order matters —
    /// `shiftTabPresses(from:to:)` derives press counts from these indices.
    static let cycle: [ClaudeMode] = [.normal, .autoAccept, .plan]

    /// How many Shift+Tab presses are needed to move from `from` mode to `to` mode
    /// inside Claude Code's three-mode cycle. 0 if already there. Always returns
    /// 0…2 (the cycle has length 3, so the longest forward path is 2 presses).
    static func shiftTabPresses(from: ClaudeMode, to: ClaudeMode) -> Int {
        guard let fromIdx = cycle.firstIndex(of: from),
              let toIdx = cycle.firstIndex(of: to) else { return 0 }
        return (toIdx - fromIdx + cycle.count) % cycle.count
    }
}

struct WindowFrame: Codable, Sendable, Equatable, Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct StateChangeMessage: Codable, Sendable {
    let type: String
    let windowId: String
    let state: String

    init(windowId: String, state: String) {
        self.type = "state_change"
        self.windowId = windowId
        self.state = state
    }
}

// MARK: - iPhone → Mac Messages

struct SelectWindowMessage: Codable, Sendable {
    let type: String
    let windowId: String

    init(windowId: String) {
        self.type = "select_window"
        self.windowId = windowId
    }
}

struct SendTextMessage: Codable, Sendable {
    let type: String
    let windowId: String
    let text: String
    let pressReturn: Bool

    init(windowId: String, text: String, pressReturn: Bool = true) {
        self.type = "send_text"
        self.windowId = windowId
        self.text = text
        self.pressReturn = pressReturn
    }
}

struct QuickActionMessage: Codable, Sendable {
    let type: String
    let windowId: String
    let action: String

    init(windowId: String, action: String) {
        self.type = "quick_action"
        self.windowId = windowId
        self.action = action
    }
}

struct STTStateMessage: Codable, Sendable {
    let type: String
    let windowId: String

    init(type: String, windowId: String) {
        self.type = type
        self.windowId = windowId
    }

    static func started(windowId: String) -> STTStateMessage {
        STTStateMessage(type: "stt_started", windowId: windowId)
    }

    static func ended(windowId: String) -> STTStateMessage {
        STTStateMessage(type: "stt_ended", windowId: windowId)
    }
}

/// iPhone → Mac. Asks the Mac to spawn a new iTerm2 window in the same
/// working directory as the source window, running the configured command.
struct DuplicateWindowMessage: Codable, Sendable {
    let type: String
    let sourceWindowId: String

    init(sourceWindowId: String) {
        self.type = "duplicate_window"
        self.sourceWindowId = sourceWindowId
    }
}

/// iPhone → Mac. Asks the Mac to actually close a specific iTerm2 window
/// (destructive — kills any running command in that session).
struct CloseWindowMessage: Codable, Sendable {
    let type: String
    let windowId: String

    init(windowId: String) {
        self.type = "close_window"
        self.windowId = windowId
    }
}

/// iPhone → Mac. Asks the Mac to spawn a new iTerm2 window in the given
/// directory, running the configured spawn command.
struct SpawnWindowMessage: Codable, Sendable {
    let type: String
    let directory: String

    init(directory: String) {
        self.type = "spawn_window"
        self.directory = directory
    }
}

/// iPhone → Mac. Asks the Mac to evenly arrange all enabled windows on the
/// main display, either side-by-side (`layout == "horizontal"`) or stacked
/// top-to-bottom (`layout == "vertical"`). Any other value is rejected on
/// the Mac side. Mac uses the existing LayoutCalculator + arrangeWindows
/// path — same one the menu-bar "Arrange Windows" button triggers.
struct ArrangeWindowsMessage: Codable, Sendable {
    let type: String
    let layout: String  // "horizontal" or "vertical"

    init(layout: String) {
        self.type = "arrange_windows"
        self.layout = layout
    }
}

/// Mac → iPhone. Sends the list of project directories configured in
/// Mac Settings so the iPhone can offer a "new window" picker.
struct ProjectDirectoriesMessage: Codable, Sendable {
    let type: String
    let directories: [String]

    init(directories: [String]) {
        self.type = "project_directories"
        self.directories = directories
    }
}

struct RequestContentMessage: Codable, Sendable {
    let type: String
    let windowId: String

    init(windowId: String) {
        self.type = "request_content"
        self.windowId = windowId
    }
}

struct TerminalContentMessage: Codable, Sendable {
    let type: String
    let windowId: String
    let content: String
    let screenshot: String?
    /// URLs extracted from `content` on the Mac (http/https/mailto only,
    /// no bare-TLD false positives — same scheme filter as the iOS linkifier).
    /// Surfaced so iOS can render a tap-to-open URL tray alongside the
    /// screenshot, which is otherwise pixels and can't be linkified.
    /// Optional for backwards compat with pre-tray Mac builds.
    let urls: [String]?

    init(windowId: String, content: String, screenshot: String? = nil, urls: [String]? = nil) {
        self.type = "terminal_content"
        self.windowId = windowId
        self.content = content
        self.screenshot = screenshot
        self.urls = urls
    }
}

struct OutputDeltaMessage: Codable, Sendable {
    let type: String
    let windowId: String
    let windowName: String
    let text: String
    let isFinal: Bool

    init(windowId: String, windowName: String, text: String, isFinal: Bool = true) {
        self.type = "output_delta"
        self.windowId = windowId
        self.windowName = windowName
        self.text = text
        self.isFinal = isFinal
    }
}

/// Pre-synthesized audio for TTS playback on the client. Streams sentence-by-sentence —
/// each message is one sentence's worth of audio. `sessionId` identifies a response batch;
/// iOS plays chunks with the same sessionId in sequence and cancels the queue when a new
/// sessionId arrives. `isFinal` marks the last chunk in a session.
struct TTSAudioMessage: Codable, Sendable {
    let type: String
    let windowId: String
    let windowName: String
    let sessionId: String
    let sequence: Int
    let isFinal: Bool
    let audioBase64: String
    let format: String  // "wav"

    init(windowId: String, windowName: String, sessionId: String, sequence: Int,
         isFinal: Bool, audioBase64: String, format: String = "wav") {
        self.type = "tts_audio"
        self.windowId = windowId
        self.windowName = windowName
        self.sessionId = sessionId
        self.sequence = sequence
        self.isFinal = isFinal
        self.audioBase64 = audioBase64
        self.format = format
    }
}

/// Mac → iPhone. Sent when the Mac drops a message (unknown window, throttled,
/// decode failure, etc.) so the phone can show feedback instead of silently
/// swallowing the tap.
struct ErrorMessage: Codable, Sendable {
    let type: String
    let reason: String

    init(reason: String) {
        self.type = "error"
        self.reason = reason
    }
}

// MARK: - Image Upload

/// iPhone → Mac. Carries a single image to be attached to a terminal.
/// `data` is the image bytes base64-encoded as a string (standard base64, no URL-safe variant).
/// Post-encoding message size must be ≤ 10 MB (enforced on the sender side).
struct ImageUploadMessage: Codable, Sendable {
    let type: String
    let imageId: String
    let windowId: String
    let filename: String
    let mimeType: String
    let data: String

    init(imageId: String, windowId: String, filename: String, mimeType: String, data: String) {
        self.type = "image_upload"
        self.imageId = imageId
        self.windowId = windowId
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

/// Mac → iPhone. Sent after the image was written to disk and the path was pasted.
struct ImageUploadAckMessage: Codable, Sendable {
    let type: String
    let imageId: String
    let savedPath: String

    init(imageId: String, savedPath: String) {
        self.type = "image_upload_ack"
        self.imageId = imageId
        self.savedPath = savedPath
    }
}

/// Mac → iPhone. Sent on any failure (decode error, unknown window, disk write error, etc.).
struct ImageUploadErrorMessage: Codable, Sendable {
    let type: String
    let imageId: String
    let reason: String

    init(imageId: String, reason: String) {
        self.type = "image_upload_error"
        self.imageId = imageId
        self.reason = reason
    }
}

// MARK: - Attach Existing iTerm Window

/// iPhone → Mac. Asks the Mac to enumerate every iTerm2 window it can see so
/// the phone can show the user a "pick one to attach" list. Empty body beyond
/// `type`.
struct ScanITermWindowsMessage: Codable, Sendable {
    let type: String

    init() { self.type = "scan_iterm_windows" }
}

/// Mac → iPhone. One row in the scan result — mirrors
/// `WindowManager.ITermWindowDescriptor` but flattened for the wire. The
/// `isAlreadyTracked` flag lets the UI dim rows that are already in Quip's
/// window list so the user doesn't double-attach.
struct ITermWindowInfo: Codable, Sendable, Equatable, Hashable {
    /// CG / iTerm window number — stable for the lifetime of the window
    /// but reassigned across iTerm relaunches, so always pair with sessionId.
    let windowNumber: Int
    let title: String
    /// iTerm2 session `unique id`. Persists across iTerm restarts for
    /// undetached sessions — this is the primary identity.
    let sessionId: String
    /// Current working directory of the session's shell.
    let cwd: String
    /// True when the session is already promoted to a Quip-tracked window.
    let isAlreadyTracked: Bool
    /// iTerm window's miniaturized state at scan time. UI shows these
    /// dimmed and tagged so the user can tell them apart.
    let isMiniaturized: Bool
}

/// Mac → iPhone. Response to a scan request.
struct ITermWindowListMessage: Codable, Sendable {
    let type: String
    let windows: [ITermWindowInfo]

    init(windows: [ITermWindowInfo]) {
        self.type = "iterm_window_list"
        self.windows = windows
    }
}

/// iPhone → Mac. User picked a row from the scan list — promote it to a
/// tracked Quip window.
struct AttachITermWindowMessage: Codable, Sendable {
    let type: String
    let windowNumber: Int
    let sessionId: String

    init(windowNumber: Int, sessionId: String) {
        self.type = "attach_iterm_window"
        self.windowNumber = windowNumber
        self.sessionId = sessionId
    }
}

// MARK: - Push Notifications

/// iPhone → Mac. Hands over the APNs device token so the Mac can push to
/// this device. `environment` is `"development"` or `"production"` — must
/// match the aps-environment entitlement the iOS app was signed with,
/// because a dev-env token won't work against prod APNs (or vice-versa).
struct RegisterPushDeviceMessage: Codable, Sendable {
    let type: String
    let deviceToken: String
    let environment: String

    init(deviceToken: String, environment: String) {
        self.type = "register_push_device"
        self.deviceToken = deviceToken
        self.environment = environment
    }
}

/// iPhone → Mac. User's notification preferences. Synced on every toggle
/// change AND on every successful reconnect so the Mac is always working
/// with current prefs. Per-device: stored on the Mac keyed by the
/// device token so a shared account with two phones behaves independently.
///
/// `quietHoursStart` / `quietHoursEnd` are hours of day (0-23) in the
/// phone's local time zone (identified by `timeZone`).
/// nil start/end = quiet hours disabled.
struct PushPreferencesMessage: Codable, Sendable {
    let type: String
    let deviceToken: String
    let paused: Bool
    let quietHoursStart: Int?
    let quietHoursEnd: Int?
    let sound: Bool
    let foregroundBanner: Bool
    /// Master toggle for APNs banner alerts. When false, the Mac skips the
    /// APNs push entirely — Live Activities still update via WebSocket, so
    /// the user can opt into "island-only" notification behavior without
    /// lock-screen / notification-center noise. Optional in the wire format
    /// so older iOS clients (that don't know about this field) still decode
    /// cleanly as banner-on.
    let bannerEnabled: Bool?
    /// IANA time-zone identifier (e.g. "America/Phoenix") for the phone
    /// that set these prefs. The Mac uses it to evaluate `quietHoursStart`/
    /// `End` against the user's intent rather than the Mac's own TZ, which
    /// matters when the two machines aren't co-located (travel, VPS host).
    /// Optional so older iOS clients decode cleanly — the Mac falls back
    /// to its own `Calendar.current` in that case.
    let timeZone: String?

    init(deviceToken: String, paused: Bool, quietHoursStart: Int?, quietHoursEnd: Int?,
         sound: Bool, foregroundBanner: Bool, bannerEnabled: Bool? = nil,
         timeZone: String? = nil) {
        self.type = "push_preferences"
        self.deviceToken = deviceToken
        self.paused = paused
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.sound = sound
        self.foregroundBanner = foregroundBanner
        self.bannerEnabled = bannerEnabled
        self.timeZone = timeZone
    }
}

// MARK: - Preferences Backup Messages

/// Bundle of phone preferences that survive a reinstall by being mirrored
/// to the Mac. Connection-specific keys (lastURL, recentConnectionsData)
/// are intentionally excluded — those are tied to the current install's
/// network state and shouldn't move between installs. Each field optional
/// so we only persist values the user has actually touched.
struct PreferencesSnapshot: Codable, Sendable, Equatable {
    var enabledQuickButtons: String?
    var tintContentBorder: Bool?
    var contentZoomLevel: Int?
    var terminalHeightFraction: Double?
    var terminalWidthFraction: Double?
    var pushPaused: Bool?
    var pushBannerEnabled: Bool?
    var pushSound: Bool?
    var pushForegroundBanner: Bool?
    var pushQuietHoursEnabled: Bool?
    var pushQuietHoursStart: Int?
    var pushQuietHoursEnd: Int?
    var liveActivitiesEnabled: Bool?
    var ttsEnabled: Bool?

    init(
        enabledQuickButtons: String? = nil,
        tintContentBorder: Bool? = nil,
        contentZoomLevel: Int? = nil,
        terminalHeightFraction: Double? = nil,
        terminalWidthFraction: Double? = nil,
        pushPaused: Bool? = nil,
        pushBannerEnabled: Bool? = nil,
        pushSound: Bool? = nil,
        pushForegroundBanner: Bool? = nil,
        pushQuietHoursEnabled: Bool? = nil,
        pushQuietHoursStart: Int? = nil,
        pushQuietHoursEnd: Int? = nil,
        liveActivitiesEnabled: Bool? = nil,
        ttsEnabled: Bool? = nil
    ) {
        self.enabledQuickButtons = enabledQuickButtons
        self.tintContentBorder = tintContentBorder
        self.contentZoomLevel = contentZoomLevel
        self.terminalHeightFraction = terminalHeightFraction
        self.terminalWidthFraction = terminalWidthFraction
        self.pushPaused = pushPaused
        self.pushBannerEnabled = pushBannerEnabled
        self.pushSound = pushSound
        self.pushForegroundBanner = pushForegroundBanner
        self.pushQuietHoursEnabled = pushQuietHoursEnabled
        self.pushQuietHoursStart = pushQuietHoursStart
        self.pushQuietHoursEnd = pushQuietHoursEnd
        self.liveActivitiesEnabled = liveActivitiesEnabled
        self.ttsEnabled = ttsEnabled
    }
}

/// iPhone → Mac. Sent every time a tracked preference changes (debounced).
/// Mac stores the snapshot in UserDefaults keyed by `deviceID` so multiple
/// phones each have their own backup.
struct PreferenceSnapshotMessage: Codable, Sendable {
    let type: String
    let deviceID: String
    let preferences: PreferencesSnapshot

    init(deviceID: String, preferences: PreferencesSnapshot) {
        self.type = "preferences_snapshot"
        self.deviceID = deviceID
        self.preferences = preferences
    }
}

/// iPhone → Mac. Sent on each WebSocket auth so the phone can pull back
/// its preferences after a reinstall. Mac responds with `PreferenceRestoreMessage`
/// (with empty preferences if no backup exists for this deviceID).
struct PreferenceRequestMessage: Codable, Sendable {
    let type: String
    let deviceID: String

    init(deviceID: String) {
        self.type = "preferences_request"
        self.deviceID = deviceID
    }
}

/// Mac → iPhone in response to `PreferenceRequestMessage`. The phone applies
/// these into UserDefaults during a brief sync-suppression window so it
/// doesn't echo the restore right back to the Mac.
struct PreferenceRestoreMessage: Codable, Sendable {
    let type: String
    let preferences: PreferencesSnapshot

    init(preferences: PreferencesSnapshot) {
        self.type = "preferences_restore"
        self.preferences = preferences
    }
}

// MARK: - Authentication Messages

struct AuthMessage: Codable, Sendable {
    let type: String
    let pin: String

    init(pin: String) {
        self.type = "auth"
        self.pin = pin
    }
}

struct AuthResultMessage: Codable, Sendable {
    let type: String
    let success: Bool
    let error: String?

    init(success: Bool, error: String? = nil) {
        self.type = "auth_result"
        self.success = success
        self.error = error
    }
}

// MARK: - Mac Permission Status

/// One of the macOS TCC panes Quip needs the user to grant. The phone sends this
/// back via `OpenMacSettingsPaneMessage` so the Mac can pop the right pane open
/// without the user hunting through System Settings.
enum MacSettingsPane: String, Codable, Sendable, CaseIterable {
    case accessibility
    case automation
    case screenRecording
}

/// Mac → iPhone. Snapshot of what's currently granted on the Mac. Sent on
/// startup, on each new client auth, and every 5s while a client is connected.
/// Local Network is intentionally omitted — if you can read this message at all,
/// Local Network is working.
struct MacPermissionsMessage: Codable, Sendable, Equatable {
    let type: String
    let accessibility: Bool
    /// Apple Events / Automation grant for iTerm specifically. Probed via
    /// `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)` against
    /// iTerm's bundle ID. If iTerm isn't running we report `true` rather than
    /// false-alarm — the alternative is a red dot every time the user hasn't
    /// launched iTerm yet.
    let appleEvents: Bool
    let screenRecording: Bool

    init(accessibility: Bool, appleEvents: Bool, screenRecording: Bool) {
        self.type = "mac_permissions"
        self.accessibility = accessibility
        self.appleEvents = appleEvents
        self.screenRecording = screenRecording
    }

    /// 0-3 — number of perms currently denied. Used by the Live Activity badge
    /// and by the in-app sheet's "any denied" footer.
    var deniedCount: Int {
        (accessibility ? 0 : 1) + (appleEvents ? 0 : 1) + (screenRecording ? 0 : 1)
    }
}

/// iPhone → Mac. Tap-to-open shortcut: Mac calls `NSWorkspace.shared.open(...)`
/// with the matching `x-apple.systempreferences:` URL so the right pane pops up
/// without the user navigating System Settings manually.
struct OpenMacSettingsPaneMessage: Codable, Sendable {
    let type: String
    let pane: MacSettingsPane

    init(pane: MacSettingsPane) {
        self.type = "open_mac_settings_pane"
        self.pane = pane
    }
}

// MARK: - Message Encoding/Decoding Helpers

enum MessageCoder {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    static let decoder = JSONDecoder()

    static func encode<T: Codable>(_ message: T) -> Data? {
        try? encoder.encode(message)
    }

    static func decode<T: Codable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder.decode(type, from: data)
    }

    static func messageType(from data: Data) -> String? {
        guard let envelope = try? decoder.decode(WSMessage.self, from: data) else { return nil }
        return envelope.type
    }
}
