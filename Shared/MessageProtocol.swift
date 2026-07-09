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

/// Which AI-coding CLI is running inside a terminal window. Orthogonal to
/// `TerminalApp` (the host app — iTerm2 / Terminal / Claude Desktop): a
/// Codex CLI session lives inside an iTerm2 host. Drives per-CLI input
/// routing: Codex's interactive composer takes pasted *image bytes* via
/// Cmd+V, Grok's composer also needs the paste path for text prompts, while
/// Claude Code accepts an *absolute path* typed inline.
/// Default `.shell` covers raw shells / unknown TUIs — same path-typing
/// fallback as before this enum existed. (GH I.)
enum CLIKind: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case grok
    case shell
    /// Cursor's agent CLI (`cursor-agent`). Routed like Claude Code by
    /// default (typed path, not pasted bytes) — its TUI accepts an inline
    /// absolute path. Added behind the iOS `labs.cursorAgent` flag. (§7.4)
    case cursor
}

/// Agent/command preset for newly spawned terminal windows.
/// `terminal` means "open a shell in the project directory without launching
/// an AI agent." Optional on spawn messages for wire compatibility: old phone
/// builds omit it, old Mac builds ignore it.
enum SpawnAgent: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case grok
    case terminal
    /// Spawn a Cursor agent session (`cursor-agent`). Surfaced in the iOS
    /// new-session picker only when the `labs.cursorAgent` flag is on. (§7.4)
    case cursor
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
    /// Which AI-coding CLI is running inside this window. Drives per-CLI
    /// input routing on the Mac (notably image upload). Optional for
    /// backward compat with older Mac builds; nil = treat as `.shell`.
    let cliKind: CLIKind?
    /// Marks windows eligible to be the "target" half of a QA mode pair.
    /// `"simulator"` for iOS Simulator (v1). `"browser_localhost"` reserved
    /// for browser-on-localhost (v2). `nil` for everything else (terminals,
    /// generic apps). Optional + string-typed for forward compat — older
    /// Mac builds omit it; older clients ignore unknown values.
    let targetKind: String?

    // Synthesized Equatable compares ALL fields including frame

    /// Backward-compat: default isThinking to false and claudeMode to nil if missing from JSON
    init(id: String, name: String, app: String, folder: String? = nil, enabled: Bool,
         frame: WindowFrame, state: String, color: String, isThinking: Bool = false,
         claudeMode: String? = nil, cliKind: CLIKind? = nil, targetKind: String? = nil) {
        self.id = id; self.name = name; self.app = app; self.folder = folder
        self.enabled = enabled
        self.frame = frame; self.state = state; self.color = color
        self.isThinking = isThinking
        self.claudeMode = claudeMode
        self.cliKind = cliKind
        self.targetKind = targetKind
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
        cliKind = try? c.decode(CLIKind.self, forKey: .cliKind)
        targetKind = try? c.decode(String.self, forKey: .targetKind)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, app, folder, enabled, frame, state, color, isThinking, claudeMode, cliKind, targetKind
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

/// Mac → iPhone. Fired when a swrm story is moved into the `in_progress`
/// column ("Started"). The Mac tails the project's `.swrm/events.ndjson`
/// (SwrmEventTailer); on a `task.moved → in_progress` event it resolves the
/// story title (file-only title cache, US-003) and broadcasts this card so
/// the phone surfaces it immediately. `taskId` is the swrm aggregateID;
/// `ts` is the event's ISO-8601 timestamp.
struct SwrmStoryStartedMessage: Codable, Sendable {
    let type: String
    let project: String
    let taskId: String
    let title: String
    let ts: String

    init(project: String, taskId: String, title: String, ts: String) {
        self.type = "swrm_story_started"
        self.project = project
        self.taskId = taskId
        self.title = title
        self.ts = ts
    }
}

/// Mac → iPhone. Fired when the Mac's frontmost tracked window changes
/// (NSWorkspace activation + AX focused-window observers, throttled). The
/// phone uses this to follow Mac focus when the user has the "Auto" pref
/// enabled — switching Mac focus from iTerm to Claude (or between two
/// iTerm windows) auto-retargets `selectedWindowId` so the next image /
/// text send lands in the window the user is actually looking at.
///
/// `windowId` is the matching `ManagedWindow.id` if Quip is currently
/// tracking the frontmost CG window, or nil when the frontmost app is
/// something Quip doesn't track (Finder, Mail, etc.) — in which case the
/// phone leaves `selectedWindowId` alone rather than blanking it.
struct FrontmostChangedMessage: Codable, Sendable {
    let type: String
    let windowId: String?

    init(windowId: String?) {
        self.type = "frontmost_changed"
        self.windowId = windowId
    }
}

/// App-level heartbeat: Mac periodically asks each authenticated client
/// "are you still processing messages?" so a wedged-but-TCP-alive iOS
/// app (background+suspended past the OS keepalive grace, foreground
/// but stuck on a runloop) gets detected at the application layer
/// rather than waiting for a TCP-level error that may never come.
/// iOS already pings Mac (WebSocket-protocol ping → pong) — this is
/// the reverse direction. iOS replies with `HeartbeatAckMessage` echoing
/// the same `seq`. (GH #19.)
struct HeartbeatMessage: Codable, Sendable {
    let type: String
    let seq: Int
    /// Mac wall-clock at send time, seconds since 1970. Diagnostic only;
    /// receiver is not expected to compare against its own clock.
    let ts: Double

    init(seq: Int, ts: Double = Date().timeIntervalSince1970) {
        self.type = "heartbeat"
        self.seq = seq
        self.ts = ts
    }
}

// MARK: - iPhone → Mac Messages

/// Reply to a Mac-side `HeartbeatMessage`. Echoes the seq so Mac can
/// match the ack to the original send and measure round-trip latency
/// if it cares to. (GH #19.)
struct HeartbeatAckMessage: Codable, Sendable {
    let type: String
    let seq: Int

    init(seq: Int) {
        self.type = "heartbeat_ack"
        self.seq = seq
    }
}

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
    /// Idempotency token (wishlist §27). Optional for backwards compat —
    /// older clients that omit it still work but won't be deduped.
    let messageId: UUID?

    init(windowId: String, text: String, pressReturn: Bool = true,
         messageId: UUID? = UUID()) {
        self.type = "send_text"
        self.windowId = windowId
        self.text = text
        self.pressReturn = pressReturn
        self.messageId = messageId
    }
}

/// Round-trip acknowledgement Mac → iOS, sent after the keystroke / paste
/// completes. Lets the phone derive `net_rtt = total_rtt - mac_ms`, which
/// separates network latency from Mac-side processing — necessary for
/// the regression detector to fire on real Mac-side slowdown without
/// crying wolf when the user is on weak Wi-Fi. Older Macs that don't
/// emit this message simply produce no ack — iOS treats absence as
/// "Mac doesn't support latency reporting" and shows --, not a fault.
struct SendTextAckMessage: Codable, Sendable {
    let type: String
    /// Echo of SendTextMessage.messageId — anchors the ack to its outbound
    /// message regardless of WS message ordering.
    let messageId: UUID
    /// Mac-side processing duration: AppleScript / paste injection only.
    /// Excludes WS handshake, focusDelay, and iTerm session resolution.
    let injectMs: Int
    /// Total Mac-side: from message-arrival on the WS to "text landed".
    /// Always >= injectMs. Difference is overhead (focusDelay, etc.).
    let totalMs: Int
    /// Routing branch — "pasteText" | "sendText". Different perf profiles;
    /// the detector buckets averages by path so a Codex-only regression
    /// doesn't get smeared by Claude's faster path.
    let path: String

    init(messageId: UUID, injectMs: Int, totalMs: Int, path: String) {
        self.type = "send_text_ack"
        self.messageId = messageId
        self.injectMs = injectMs
        self.totalMs = totalMs
        self.path = path
    }
}

struct QuickActionMessage: Codable, Sendable {
    let type: String
    let windowId: String
    let action: String
    let messageId: UUID?
    /// Fingerprint of the prompt the phone saw when it sent an answer
    /// (`select_N`/`press_y`/`press_n`). The Mac re-scrapes the window and
    /// injects only if the live prompt still hashes to this value — guards
    /// against answering a prompt the agent already moved past. Optional:
    /// nil (older phones / non-answer actions) → inject without re-validation
    /// (legacy behavior). (§3.2)
    let promptFingerprint: String?

    init(windowId: String, action: String, messageId: UUID? = UUID(),
         promptFingerprint: String? = nil) {
        self.type = "quick_action"
        self.windowId = windowId
        self.action = action
        self.messageId = messageId
        self.promptFingerprint = promptFingerprint
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
    let agent: SpawnAgent?
    let messageId: UUID?

    init(sourceWindowId: String, agent: SpawnAgent? = nil, messageId: UUID? = UUID()) {
        self.type = "duplicate_window"
        self.sourceWindowId = sourceWindowId
        self.agent = agent
        self.messageId = messageId
    }
}

/// iPhone → Mac. Asks the Mac to actually close a specific iTerm2 window
/// (destructive — kills any running command in that session).
struct CloseWindowMessage: Codable, Sendable {
    let type: String
    let windowId: String
    let messageId: UUID?

    init(windowId: String, messageId: UUID? = UUID()) {
        self.type = "close_window"
        self.windowId = windowId
        self.messageId = messageId
    }
}

/// iPhone → Mac. Asks the Mac to spawn a new iTerm2 window in the given
/// directory, running the configured spawn command.
struct SpawnWindowMessage: Codable, Sendable {
    let type: String
    let directory: String
    let agent: SpawnAgent?
    let messageId: UUID?

    init(directory: String, agent: SpawnAgent? = nil, messageId: UUID? = UUID()) {
        self.type = "spawn_window"
        self.directory = directory
        self.agent = agent
        self.messageId = messageId
    }
}

/// iPhone → Mac. Asks the Mac to evenly arrange all enabled windows on the
/// main display, either side-by-side (`layout == "horizontal"`) or stacked
/// Wire-level layout vocabulary spoken by the phone. Free-string was a
/// silent-failure trap (typos / unknown layouts produced no error path),
/// per GH #20. Codable round-trips through the lowercase rawValue so
/// existing JSON ("horizontal" / "vertical") remains unchanged.
///
/// "grid" is intentionally NOT in this enum even though the iOS phone
/// recently grew a 3-mode arrange-button cycle — phone-side grid does
/// the arrangement *locally* (see `phoneLayoutOverrideRaw`) and does
/// NOT send `arrange_windows` to the Mac. If a Mac-side grid arranger
/// is ever added, extend this enum + `LayoutMode.from(arrangeLayout:)`
/// + the Mac handler in lockstep.
enum ArrangeLayout: String, Codable, Sendable, CaseIterable {
    case horizontal
    case vertical
}

/// top-to-bottom (`layout == .vertical`). Any other value fails Codable
/// decode loudly — silent fallthrough was the bug GH #20 is about. Mac
/// uses the existing LayoutCalculator + arrangeWindows path — same one
/// the menu-bar "Arrange Windows" button triggers.
struct ArrangeWindowsMessage: Codable, Sendable {
    let type: String
    let layout: ArrangeLayout

    init(layout: ArrangeLayout) {
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
    /// True when the Mac detected an inline autosuggestion (greyed ghost
    /// text) on this window's input line, via `AutosuggestDetector`. Gates
    /// the iOS accept-autocomplete button so it never fires into empty air.
    /// Decodes as false when absent so pre-autosuggest Mac builds keep
    /// working (additive-field pattern).
    let hasAutosuggest: Bool

    init(windowId: String, content: String, screenshot: String? = nil, urls: [String]? = nil,
         hasAutosuggest: Bool = false) {
        self.type = "terminal_content"
        self.windowId = windowId
        self.content = content
        self.screenshot = screenshot
        self.urls = urls
        self.hasAutosuggest = hasAutosuggest
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        windowId = try c.decode(String.self, forKey: .windowId)
        content = try c.decode(String.self, forKey: .content)
        screenshot = try? c.decode(String.self, forKey: .screenshot)
        urls = try? c.decode([String].self, forKey: .urls)
        hasAutosuggest = (try? c.decode(Bool.self, forKey: .hasAutosuggest)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case type, windowId, content, screenshot, urls, hasAutosuggest
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
    let messageId: UUID?

    init(windowNumber: Int, sessionId: String, messageId: UUID? = UUID()) {
        self.type = "attach_iterm_window"
        self.windowNumber = windowNumber
        self.sessionId = sessionId
        self.messageId = messageId
    }
}

// MARK: - Prompt Library (wishlist §57)

/// Mac → iPhone. Catalog of named prompts the Mac has on disk under
/// `~/Library/Application Support/Quip/prompts/*.txt`. Phone renders
/// them as a list in Settings → Prompts; tapping one fires
/// `paste_prompt` back, the Mac then sendText's the body into the
/// active iTerm session. Mirrors the Stream Deck "clipboard prompt"
/// pattern (paste a long pre-written prompt with one press) but
/// without needing Stream Deck hardware or the .scpt round-trip.
struct PromptLibraryMessage: Codable, Sendable {
    let type: String
    let prompts: [PromptEntry]

    init(prompts: [PromptEntry]) {
        self.type = "prompt_library"
        self.prompts = prompts
    }
}

/// One row in the prompt library. `id` is the filename without
/// extension (used as the lookup key on `paste_prompt`); `label` is
/// the display name (defaults to id but can carry a friendlier title
/// if the file's first non-empty line starts with `# `, in which case
/// that line becomes the label and gets stripped from the body).
/// `body` carries the full prompt text so the iPhone can edit without
/// a second round-trip to the Mac.
struct PromptEntry: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let label: String
    let body: String
    /// Optional pack metadata (§6.1). All nil for plain `.txt` prompts and
    /// older peers — additive, so existing prompts and old Mac/phone builds
    /// keep working unchanged.
    let tags: [String]?
    let targetAgent: String?  // "claude" | "codex" | "cursor" | "grok" | "any"
    let description: String?

    /// Convenience for the iOS list row — first 120 chars of the
    /// body, used as a single-line preview.
    var bodyPreview: String { String(body.prefix(120)) }
    var bodyBytes: Int { body.utf8.count }

    /// True when this prompt was inherited from VibeCut (carries the provenance
    /// tag written by `VibeCutPromptMapper`). Drives the iOS "VibeCut" badge and
    /// the per-prompt hide filter. Never the deletion selector on the Mac —
    /// re-sync keys off the reserved `vibecut__` filename namespace instead.
    var isInherited: Bool { tags?.contains(VibeCutPromptMapper.providerTag) == true }

    init(id: String, label: String, body: String,
         tags: [String]? = nil, targetAgent: String? = nil, description: String? = nil) {
        self.id = id
        self.label = label
        self.body = body
        self.tags = tags
        self.targetAgent = targetAgent
        self.description = description
    }
}

/// iPhone → Mac. User tapped a prompt — paste its body into the
/// currently-targeted window. Mac looks up by id and runs sendText.
struct PastePromptMessage: Codable, Sendable {
    let type: String
    let id: String
    let windowId: String
    let pressReturn: Bool
    let messageId: UUID?

    init(id: String, windowId: String, pressReturn: Bool = false,
         messageId: UUID? = UUID()) {
        self.type = "paste_prompt"
        self.id = id
        self.windowId = windowId
        self.pressReturn = pressReturn
        self.messageId = messageId
    }
}

/// iPhone → Mac. Create or update a prompt on disk. Mac writes the
/// file to `~/Library/Application Support/Quip/prompts/<id>.txt`
/// (with `# label\n\n` header so the friendly title round-trips), the
/// FS watcher fires, and the new catalog is broadcast back to all
/// clients including the originator. (wishlist §57 v2)
struct PutPromptMessage: Codable, Sendable {
    let type: String
    let id: String
    let label: String
    let body: String
    /// Correlates Mac persistence acks back to the mobile save action.
    /// Optional so older clients can still write prompts without ack support.
    let messageId: UUID?
    /// Optional pack metadata (§6.1) — persisted by the Mac as on-disk
    /// front-matter. All optional → old peers ignore / send nil.
    let tags: [String]?
    let targetAgent: String?
    let description: String?

    init(id: String, label: String, body: String,
         messageId: UUID? = UUID(),
         tags: [String]? = nil, targetAgent: String? = nil, description: String? = nil) {
        self.type = "put_prompt"
        self.id = id
        self.label = label
        self.body = body
        self.messageId = messageId
        self.tags = tags
        self.targetAgent = targetAgent
        self.description = description
    }
}

/// Mac → iPhone. Confirms a prompt create/update reached disk, or returns the
/// failure reason so the editor can stay open and show a specific error.
struct PutPromptAckMessage: Codable, Sendable {
    let type: String
    let messageId: UUID
    let id: String
    let success: Bool
    let error: String?

    init(messageId: UUID, id: String, success: Bool, error: String? = nil) {
        self.type = "put_prompt_ack"
        self.messageId = messageId
        self.id = id
        self.success = success
        self.error = error
    }
}

/// iPhone → Mac. Delete a prompt by id (removes the .txt file).
struct DeletePromptMessage: Codable, Sendable {
    let type: String
    let id: String
    /// Correlates Mac delete acks back to the mobile destructive action.
    /// Optional for backwards compatibility with older clients.
    let messageId: UUID?

    init(id: String, messageId: UUID? = UUID()) {
        self.type = "delete_prompt"
        self.id = id
        self.messageId = messageId
    }
}

/// Mac → iPhone. Confirms a prompt delete reached disk, or returns the failure
/// reason so the phone can show recoverable feedback.
struct DeletePromptAckMessage: Codable, Sendable {
    let type: String
    let messageId: UUID
    let id: String
    let success: Bool
    let error: String?

    init(messageId: UUID, id: String, success: Bool, error: String? = nil) {
        self.type = "delete_prompt_ack"
        self.messageId = messageId
        self.id = id
        self.success = success
        self.error = error
    }
}

/// iPhone → Mac. Trigger a one-way re-sync of the prompt catalog from VibeCut
/// (`<vibecut-repo>/shared/prompts.json`). The Mac reads that file, maps its real
/// text prompts into the `vibecut__*` reserved namespace, replaces the prior
/// inherited set on disk, and broadcasts the refreshed `prompt_library` as usual
/// plus the ack below. No auto/live sync — this is manual, user-tapped only.
struct SyncVibeCutMessage: Codable, Sendable {
    let type: String
    let messageId: UUID?

    init(messageId: UUID? = UUID()) {
        self.type = "sync_vibecut"
        self.messageId = messageId
    }
}

/// Mac → iPhone. Confirms a VibeCut sync completed: how many prompts were landed
/// and how many source entries were skipped by the include filter, or the reason
/// the sync could not run (e.g. the VibeCut repo was not found). On error the
/// Mac leaves the existing inherited set untouched.
struct SyncVibeCutAckMessage: Codable, Sendable {
    let type: String
    let messageId: UUID
    let syncedCount: Int
    let skippedCount: Int
    /// Number of pack `.json` files under VibeCut's packs directory that could
    /// not be decoded and were skipped. Optional for wire back-compat: an older
    /// Mac omits it (decodes as nil) and an older phone ignores it.
    let skippedPacks: Int?
    let error: String?

    init(messageId: UUID, syncedCount: Int, skippedCount: Int,
         skippedPacks: Int? = nil, error: String? = nil) {
        self.type = "sync_vibecut_ack"
        self.messageId = messageId
        self.syncedCount = syncedCount
        self.skippedCount = skippedCount
        self.skippedPacks = skippedPacks
        self.error = error
    }
}

// MARK: - Diagnostics Bundle

/// iPhone → Mac. Asks the Mac to bundle its three log files
/// (`websocket.log`, `push.log`, `kokoro.log`) plus a `system-info.txt`
/// blob into a single zip and ship it back over the WebSocket. Used by
/// the Connection diagnostics sheet to short-circuit the
/// "tail this for me, then this one, then this one" support cycle.
struct RequestDiagnosticsMessage: Codable, Sendable {
    let type: String

    init() { self.type = "request_diagnostics" }
}

/// Mac → iPhone. Response to `request_diagnostics`. Carries the zip as
/// base64. Mac caps total size at ~4 MiB (well under the 16 MiB WS
/// payload cap, leaving headroom for base64's ~33% inflation); if the
/// raw logs exceed that, the Mac sets `errorReason` and omits `data`,
/// pointing the user at the Mac-side share button instead.
struct DiagnosticsBundleMessage: Codable, Sendable {
    let type: String
    let filename: String
    let sizeBytes: Int
    /// Base64-encoded zip body. nil when `errorReason` is set.
    let data: String?
    let errorReason: String?

    init(filename: String, sizeBytes: Int, data: String?, errorReason: String? = nil) {
        self.type = "diagnostics_bundle"
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.data = data
        self.errorReason = errorReason
    }
}

/// iPhone → Mac. Asks the Mac for a tail snapshot of its three log
/// files — text only, no zip. Auto-fired by the Connection diagnostics
/// sheet on appear, so the user sees recent events without tapping a
/// button. The full zip download stays as the explicit "Get Mac logs"
/// path for AirDrop / save-to-Files use cases.
struct RequestLogTailMessage: Codable, Sendable {
    let type: String
    /// How many bytes per file to return from the tail. Default 16 KiB
    /// is enough for ~200 lines per file at typical log density. Mac
    /// clamps to a max so a misbehaving phone can't pull whole logs.
    let bytesPerFile: Int

    init(bytesPerFile: Int = 16 * 1024) {
        self.type = "request_log_tail"
        self.bytesPerFile = bytesPerFile
    }
}

/// Mac → iPhone. Response to `request_log_tail`. Carries the tail of
/// each of the three log files as raw text, concatenated with file
/// headers. Phone renders inline in a scrollable monospace view.
struct LogTailMessage: Codable, Sendable {
    let type: String
    /// Concatenated text — sections separated by `=== <filename> ===`
    /// headers. Empty if no logs exist yet.
    let text: String
    /// Total byte count of `text` (UTF-8). Used by phone for a "5.2 KB"
    /// label without re-counting.
    let totalBytes: Int
    /// ISO-8601 timestamp of when the snapshot was captured. Phone
    /// shows "captured at HH:mm:ss" so user knows the staleness.
    let capturedAt: String

    init(text: String, totalBytes: Int, capturedAt: String) {
        self.type = "log_tail"
        self.text = text
        self.totalBytes = totalBytes
        self.capturedAt = capturedAt
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
    /// (wishlist §15.) When true, Mac fires waiting_for_input pushes for
    /// EVERY enabled window, not just the one the phone has selected. When
    /// false (default), only the selected window pushes — the existing
    /// "no notification flood from background Claudes" stance.
    /// Optional in the wire format so older iOS clients decode cleanly as
    /// `nil` → Mac treats as `false`.
    let notifyAllWindows: Bool?

    init(deviceToken: String, paused: Bool, quietHoursStart: Int?, quietHoursEnd: Int?,
         sound: Bool, foregroundBanner: Bool, bannerEnabled: Bool? = nil,
         timeZone: String? = nil, notifyAllWindows: Bool? = nil) {
        self.type = "push_preferences"
        self.deviceToken = deviceToken
        self.paused = paused
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.sound = sound
        self.foregroundBanner = foregroundBanner
        self.bannerEnabled = bannerEnabled
        self.timeZone = timeZone
        self.notifyAllWindows = notifyAllWindows
    }
}

// MARK: - Preferences Backup Messages

/// Bundle of phone preferences that survive a reinstall by being mirrored
/// to the Mac. Connection memory (paired backends + recent connections) IS
/// backed up here BY DESIGN (per repeated user request: reinstalls must
/// remember known LANs) — a change from the earlier policy that excluded it.
/// The phone MERGES these into live state on restore, never clobbers, and
/// only ships them to the user's own Mac over the authenticated socket.
/// `lastURL` (legacy single-backend) stays excluded — superseded by
/// `pairedBackendsJSON`. Each field optional so we only persist values the
/// user has actually touched and mixed-version peers drop unknown keys.
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
    /// (wishlist §15.) Optional so older Macs decode cleanly as nil →
    /// phone keeps whatever local default it had.
    var pushNotifyAllWindows: Bool?
    var liveActivitiesEnabled: Bool?
    var ttsEnabled: Bool?
    /// JSON-encoded ordered slot list from the Apple-toolbar-style editor.
    /// Supersedes `enabledQuickButtons` (kept for downgrade safety) — the
    /// CSV is regenerated from the slot list's built-in entries on each
    /// edit. Optional so older Macs without this field stay forward-
    /// compatible.
    var quickSlotsJSON: String?
    /// JSON-encoded `[CustomButton]` definitions table referenced by the
    /// slot list via UUID. Persisted separately so re-ordering doesn't
    /// rewrite definitions.
    var customButtonsJSON: String?
    /// (wishlist §B16.) Whether the phone auto-retargets `selectedWindowId`
    /// to follow the Mac's frontmost window. Optional so older Macs decode
    /// cleanly as nil → phone keeps whatever local default it had.
    var followFrontmost: Bool?
    /// Connection memory, backed up across reinstalls (see struct doc). The
    /// phone merges these into live state on restore — it does not overwrite.
    /// JSON text of the phone's `pairedBackendsData` blob (`[PairedBackend]`).
    var pairedBackendsJSON: String?
    /// JSON text of the phone's `recentConnectionsData` blob (`[SavedConnection]`).
    var recentConnectionsJSON: String?
    /// Which backend was active, so a reinstalled phone re-selects it.
    var activeBackendID: String?

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
        pushNotifyAllWindows: Bool? = nil,
        liveActivitiesEnabled: Bool? = nil,
        ttsEnabled: Bool? = nil,
        quickSlotsJSON: String? = nil,
        customButtonsJSON: String? = nil,
        followFrontmost: Bool? = nil,
        pairedBackendsJSON: String? = nil,
        recentConnectionsJSON: String? = nil,
        activeBackendID: String? = nil
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
        self.pushNotifyAllWindows = pushNotifyAllWindows
        self.liveActivitiesEnabled = liveActivitiesEnabled
        self.ttsEnabled = ttsEnabled
        self.quickSlotsJSON = quickSlotsJSON
        self.customButtonsJSON = customButtonsJSON
        self.followFrontmost = followFrontmost
        self.pairedBackendsJSON = pairedBackendsJSON
        self.recentConnectionsJSON = recentConnectionsJSON
        self.activeBackendID = activeBackendID
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

// MARK: - QA Mode

/// iPhone → Mac. Set the QA pair for THIS connection. Mac will filter
/// its `LayoutUpdate` broadcast to ONLY these two windows for this
/// client. Pair is per-connection — one phone in QA mode does not affect
/// other phones connected to the same Mac.
struct SetQAPairMessage: Codable, Sendable {
    let type: String
    let targetId: String
    let terminalId: String

    init(targetId: String, terminalId: String) {
        self.type = "set_qa_pair"
        self.targetId = targetId
        self.terminalId = terminalId
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case targetId = "target_id"
        case terminalId = "terminal_id"
    }
}

/// iPhone → Mac. Drops the QA pair for this connection. Subsequent
/// `LayoutUpdate` broadcasts return to the unfiltered (mirrorDesktop +
/// isEnabled) rules.
struct ClearQAPairMessage: Codable, Sendable {
    let type: String

    init() {
        self.type = "clear_qa_pair"
    }
}

/// Mac → iPhone. Either paired window vanished from the snapshot, or the
/// pair the phone replayed on reconnect doesn't match a current window.
/// Phone exits QA mode and shows a toast.
///
/// `reason` is a free-form string for forward compat — see `Reason` for the
/// canonical producer-side constants:
/// - `Reason.windowClosed` — window left the snapshot
/// - `Reason.windowOffscreen` — `isOnVisibleScreen == false` for >5s
/// - `Reason.connectionReset` — Mac doesn't recognize the IDs (post-restart replay)
struct QAPairLostMessage: Codable, Sendable {
    /// Centralized reason codes. Matches the `reason` strings on the wire.
    /// String-typed (not `enum`) so older clients receiving an unknown
    /// reason don't fail to decode the surrounding message — the raw
    /// reason field stays a `String`. Producers should use these constants.
    enum Reason {
        static let windowClosed = "window_closed"
        static let windowOffscreen = "window_offscreen"
        static let connectionReset = "connection_reset"
    }

    let type: String
    let missingId: String
    let reason: String

    init(missingId: String, reason: String) {
        self.type = "qa_pair_lost"
        self.missingId = missingId
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case missingId = "missing_id"
        case reason
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

// MARK: - Device Identity

/// Backend → iPhone. Sent immediately after `auth_result(success: true)` so the
/// phone can key per-backend state (PIN in Keychain, paired-backend row, etc.)
/// against a stable UUID rather than a URL that changes with network. Daemons
/// generate `deviceID` once on first launch and persist it (Mac: UserDefaults
/// `quip.deviceID`; Linux: settings store next to the PIN).
struct DeviceIdentityMessage: Codable, Sendable {
    let type: String
    let deviceID: String   // UUIDv4
    let deviceKind: String // "mac" | "linux" | "ios" | "watchos"
    let displayName: String
    /// Ready-to-use LAN WebSocket URLs the daemon is reachable on over the
    /// local network, e.g. `["ws://192.168.1.50:8765"]`. The phone merges
    /// these into the backend's fallback URL list so a "Use Local Network"
    /// switch is possible even when the phone only ever paired over Tailscale
    /// (and so the LAN path was never otherwise learned). Optional / nil from
    /// peers that don't supply it (iOS self-identity, Linux daemon) — older
    /// builds that predate this field simply decode it as nil.
    let localURLs: [String]?

    init(deviceID: String, deviceKind: String, displayName: String, localURLs: [String]? = nil) {
        self.type = "device_identity"
        self.deviceID = deviceID
        self.deviceKind = deviceKind
        self.displayName = displayName
        self.localURLs = localURLs
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

    var systemSettingsURLString: String {
        switch self {
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .automation:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case .screenRecording:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
    }

    var systemSettingsURL: URL? {
        URL(string: systemSettingsURLString)
    }
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

    /// The System Settings panes for whatever's currently denied, in a stable
    /// priority order (Accessibility → Automation → Screen Recording); empty
    /// when everything is granted. Backs the menubar 'Fix Permissions…' action
    /// (US-003, GH #33): one click opens the pane(s) for whatever's missing,
    /// reusing the same `MacSettingsPane` URLs as the per-row buttons and the
    /// phone's red-❌ taps. Apple Events maps to the `.automation` pane.
    var deniedPanes: [MacSettingsPane] {
        var panes: [MacSettingsPane] = []
        if !accessibility { panes.append(.accessibility) }
        if !appleEvents { panes.append(.automation) }
        if !screenRecording { panes.append(.screenRecording) }
        return panes
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

// MARK: - Whisper PTT Messages

/// iPhone → Mac. One frame of audio from a PTT session. `pcmBase64` is standard
/// base64 of int16 little-endian mono 16 kHz PCM — nominally 100 ms (3200 bytes
/// decoded), shorter on the final frame. `isFinal == true` signals end-of-utterance
/// and triggers Whisper transcription on the Mac.
struct AudioChunkMessage: Codable, Sendable {
    let type: String
    let sessionId: UUID
    let seq: Int
    let pcmBase64: String
    let isFinal: Bool

    init(sessionId: UUID, seq: Int, pcmBase64: String, isFinal: Bool) {
        self.type = "audio_chunk"
        self.sessionId = sessionId
        self.seq = seq
        self.pcmBase64 = pcmBase64
        self.isFinal = isFinal
    }
}

/// Mac → iPhone. Final transcription result for a completed PTT session.
/// `text` is empty when `error` is set; otherwise `error` is nil.
struct TranscriptResultMessage: Codable, Sendable {
    let type: String
    let sessionId: UUID
    let text: String
    let error: String?

    init(sessionId: UUID, text: String, error: String? = nil) {
        self.type = "transcript_result"
        self.sessionId = sessionId
        self.text = text
        self.error = error
    }
}

/// Whisper model lifecycle state on the Mac. Broadcast by Mac → iPhone so the
/// phone knows whether the remote recognizer path is viable at PTT-start.
enum WhisperState: Codable, Sendable, Equatable {
    case preparing
    case downloading(progress: Double)
    case ready
    case failed(message: String)

    private enum CodingKeys: String, CodingKey { case tag, progress, message }
    private enum Tag: String, Codable { case preparing, downloading, ready, failed }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .preparing:
            try c.encode(Tag.preparing, forKey: .tag)
        case .downloading(let progress):
            try c.encode(Tag.downloading, forKey: .tag)
            try c.encode(progress, forKey: .progress)
        case .ready:
            try c.encode(Tag.ready, forKey: .tag)
        case .failed(let message):
            try c.encode(Tag.failed, forKey: .tag)
            try c.encode(message, forKey: .message)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .tag)
        switch tag {
        case .preparing: self = .preparing
        case .downloading:
            let p = try c.decode(Double.self, forKey: .progress)
            self = .downloading(progress: p)
        case .ready: self = .ready
        case .failed:
            let m = try c.decode(String.self, forKey: .message)
            self = .failed(message: m)
        }
    }
}

struct WhisperStatusMessage: Codable, Sendable {
    let type: String
    let state: WhisperState

    init(state: WhisperState) {
        self.type = "whisper_status"
        self.state = state
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
