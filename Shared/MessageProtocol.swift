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

    // Synthesized Equatable compares ALL fields including frame

    /// Backward-compat: default isThinking to false if missing from JSON
    init(id: String, name: String, app: String, folder: String? = nil, enabled: Bool,
         frame: WindowFrame, state: String, color: String, isThinking: Bool = false) {
        self.id = id; self.name = name; self.app = app; self.folder = folder
        self.enabled = enabled
        self.frame = frame; self.state = state; self.color = color
        self.isThinking = isThinking
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, app, folder, enabled, frame, state, color, isThinking
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

    init(windowId: String, content: String, screenshot: String? = nil) {
        self.type = "terminal_content"
        self.windowId = windowId
        self.content = content
        self.screenshot = screenshot
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
