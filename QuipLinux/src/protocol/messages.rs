use serde::{Deserialize, Serialize};

use super::types::WindowFrame;

// ---------------------------------------------------------------------------
// Mac -> iPhone messages
// ---------------------------------------------------------------------------

/// Layout update broadcast to all connected clients every 2 seconds
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LayoutUpdate {
    #[serde(rename = "type")]
    pub type_: String,
    pub monitor: String,
    /// width / height of the host display — lets clients render correctly
    /// proportioned thumbnails on phones with different aspect ratios.
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "screenAspect")]
    pub screen_aspect: Option<f64>,
    pub windows: Vec<WindowState>,
}

impl LayoutUpdate {
    pub fn new(monitor: String, screen_aspect: Option<f64>, windows: Vec<WindowState>) -> Self {
        Self {
            type_: "layout_update".into(),
            monitor,
            screen_aspect,
            windows,
        }
    }
}

/// State of a single window in the layout update
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WindowState {
    pub id: String,
    pub name: String,
    pub app: String,
    /// Project/folder name — shown as the primary bold label above the app
    /// name on the phone. Optional for backward compat with older clients.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<String>,
    pub enabled: bool,
    pub frame: WindowFrame,
    pub state: String,
    pub color: String,
    #[serde(default, rename = "isThinking")]
    pub is_thinking: bool,
    /// Claude Code mode scraped from terminal content. One of "normal", "plan",
    /// "autoAccept", or None if unknown / not yet detected / not a Claude window.
    /// Optional for backward compat — older clients just won't populate it.
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "claudeMode")]
    pub claude_mode: Option<String>,
}

/// Claude Code's three cyclable modes. Cycle order (Shift+Tab): normal → autoAccept → plan → normal.
/// Wire raw values must stay stable — they're shared with iOS.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ClaudeMode {
    #[serde(rename = "normal")]
    Normal,
    #[serde(rename = "plan")]
    Plan,
    #[serde(rename = "autoAccept")]
    AutoAccept,
}

impl ClaudeMode {
    /// Order Claude Code cycles through on Shift+Tab.
    pub const CYCLE: [ClaudeMode; 3] = [ClaudeMode::Normal, ClaudeMode::AutoAccept, ClaudeMode::Plan];

    pub fn as_str(self) -> &'static str {
        match self {
            ClaudeMode::Normal => "normal",
            ClaudeMode::Plan => "plan",
            ClaudeMode::AutoAccept => "autoAccept",
        }
    }

    /// How many Shift+Tab presses to walk from `from` to `to` in the 3-mode cycle.
    /// Always 0..=2.
    pub fn shift_tab_presses(from: ClaudeMode, to: ClaudeMode) -> usize {
        let from_idx = Self::CYCLE.iter().position(|m| *m == from).unwrap_or(0);
        let to_idx = Self::CYCLE.iter().position(|m| *m == to).unwrap_or(0);
        (to_idx + Self::CYCLE.len() - from_idx) % Self::CYCLE.len()
    }
}

/// Notify clients that a window's terminal state changed
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StateChangeMessage {
    #[serde(rename = "type")]
    pub type_: String,
    #[serde(rename = "windowId")]
    pub window_id: String,
    pub state: String,
}

impl StateChangeMessage {
    pub fn new(window_id: String, state: String) -> Self {
        Self {
            type_: "state_change".into(),
            window_id,
            state,
        }
    }
}

// ---------------------------------------------------------------------------
// iPhone -> Mac messages
// ---------------------------------------------------------------------------

/// Envelope used only to peek at the `type` field
#[derive(Debug, Deserialize)]
pub struct MessageEnvelope {
    #[serde(rename = "type")]
    pub type_: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SelectWindowMessage {
    #[serde(rename = "windowId")]
    pub window_id: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SendTextMessage {
    #[serde(rename = "windowId")]
    pub window_id: String,
    pub text: String,
    #[serde(rename = "pressReturn")]
    pub press_return: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct QuickActionMessage {
    #[serde(rename = "windowId")]
    pub window_id: String,
    pub action: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SttStateMessage {
    #[serde(rename = "type")]
    pub type_: String,
    #[serde(rename = "windowId")]
    pub window_id: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RequestContentMessage {
    #[serde(rename = "windowId")]
    pub window_id: String,
}

/// iPhone -> host. Asks the host to spawn a new terminal in the same folder
/// as the source window. Linux can't currently duplicate arbitrary terminals
/// so this is logged and ignored, but the message must still be parsed
/// cleanly so it doesn't get flagged as "unknown message type".
#[derive(Debug, Clone, Deserialize)]
pub struct DuplicateWindowMessage {
    #[serde(rename = "sourceWindowId")]
    pub source_window_id: String,
}

/// iPhone -> host. Asks the host to close a specific terminal window.
#[derive(Debug, Clone, Deserialize)]
pub struct CloseWindowMessage {
    #[serde(rename = "windowId")]
    pub window_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalContentMessage {
    #[serde(rename = "type")]
    pub type_: String,
    #[serde(rename = "windowId")]
    pub window_id: String,
    pub content: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub screenshot: Option<String>,
    /// URLs extracted from `content` so iOS can render the tap-to-open URL tray
    /// alongside the screenshot (which is pixels and can't be linkified).
    /// Optional for backwards compat with pre-tray hosts.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub urls: Option<Vec<String>>,
}

impl TerminalContentMessage {
    pub fn new(window_id: String, content: String) -> Self {
        Self {
            type_: "terminal_content".into(),
            window_id,
            content,
            screenshot: None,
            urls: None,
        }
    }

    pub fn with_screenshot(window_id: String, content: String, screenshot: String) -> Self {
        Self {
            type_: "terminal_content".into(),
            window_id,
            content,
            screenshot: Some(screenshot),
            urls: None,
        }
    }

    pub fn with_urls(mut self, urls: Vec<String>) -> Self {
        self.urls = Some(urls);
        self
    }
}

// ---------------------------------------------------------------------------
// Output delta — sent when Claude finishes (waiting_for_input transition)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
pub struct OutputDeltaMessage {
    #[serde(rename = "type")]
    pub type_: String,
    #[serde(rename = "windowId")]
    pub window_id: String,
    #[serde(rename = "windowName")]
    pub window_name: String,
    pub text: String,
    #[serde(rename = "isFinal")]
    pub is_final: bool,
}

impl OutputDeltaMessage {
    pub fn new(window_id: String, window_name: String, text: String, is_final: bool) -> Self {
        Self {
            type_: "output_delta".into(),
            window_id,
            window_name,
            text,
            is_final,
        }
    }
}

// ---------------------------------------------------------------------------
// Authentication messages
// ---------------------------------------------------------------------------

/// Client sends PIN to authenticate
#[derive(Debug, Clone, Deserialize)]
pub struct AuthMessage {
    pub pin: String,
}

/// Server responds with auth result
#[derive(Debug, Clone, Serialize)]
pub struct AuthResultMessage {
    #[serde(rename = "type")]
    pub type_: String,
    pub success: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl AuthResultMessage {
    pub fn success() -> Self {
        Self {
            type_: "auth_result".into(),
            success: true,
            error: None,
        }
    }

    pub fn failure(error: String) -> Self {
        Self {
            type_: "auth_result".into(),
            success: false,
            error: Some(error),
        }
    }
}

// ---------------------------------------------------------------------------
// TTS audio — streamed sentence-by-sentence to clients
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
pub struct TTSAudioMessage {
    #[serde(rename = "type")]
    #[allow(dead_code)]
    pub type_: String,
    #[serde(rename = "windowId")]
    pub window_id: String,
    #[serde(rename = "windowName")]
    pub window_name: String,
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub sequence: u32,
    #[serde(rename = "isFinal")]
    pub is_final: bool,
    #[serde(rename = "audioBase64")]
    pub audio_base64: String,
    pub format: String,
}

impl TTSAudioMessage {
    pub fn chunk(window_id: String, window_name: String, session_id: String,
                 sequence: u32, audio_base64: String) -> Self {
        Self {
            type_: "tts_audio".into(),
            window_id,
            window_name,
            session_id,
            sequence,
            is_final: false,
            audio_base64,
            format: "wav".into(),
        }
    }

    pub fn final_marker(window_id: String, window_name: String, session_id: String,
                        sequence: u32) -> Self {
        Self {
            type_: "tts_audio".into(),
            window_id,
            window_name,
            session_id,
            sequence,
            is_final: true,
            audio_base64: String::new(),
            format: "wav".into(),
        }
    }
}

// ---------------------------------------------------------------------------
// Spawn / arrange / project list
// ---------------------------------------------------------------------------

/// iPhone -> host. Asks the host to spawn a new terminal in the given directory.
#[derive(Debug, Clone, Deserialize)]
pub struct SpawnWindowMessage {
    pub directory: String,
}

/// iPhone -> host. Even-arrange all enabled windows on the main display,
/// either side-by-side ("horizontal") or stacked ("vertical").
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArrangeWindowsMessage {
    #[serde(rename = "type", default = "ArrangeWindowsMessage::default_type")]
    pub type_: String,
    pub layout: String,
}

impl ArrangeWindowsMessage {
    fn default_type() -> String { "arrange_windows".into() }
}

/// host -> iPhone. List of project directories the user has configured.
#[derive(Debug, Clone, Serialize)]
pub struct ProjectDirectoriesMessage {
    #[serde(rename = "type")]
    pub type_: String,
    pub directories: Vec<String>,
}

impl ProjectDirectoriesMessage {
    pub fn new(directories: Vec<String>) -> Self {
        Self { type_: "project_directories".into(), directories }
    }
}

/// host -> iPhone. Sent when the host drops a message so the phone can show
/// feedback instead of silently swallowing the tap.
#[derive(Debug, Clone, Serialize)]
pub struct ErrorMessage {
    #[serde(rename = "type")]
    pub type_: String,
    pub reason: String,
}

impl ErrorMessage {
    pub fn new(reason: String) -> Self {
        Self { type_: "error".into(), reason }
    }
}

// ---------------------------------------------------------------------------
// Image upload
// ---------------------------------------------------------------------------

/// iPhone -> host. Single image to be attached to a terminal. `data` is base64.
/// Post-encoding message size must be ≤ 10 MB (sender-enforced).
#[derive(Debug, Clone, Deserialize)]
pub struct ImageUploadMessage {
    #[serde(rename = "imageId")]
    pub image_id: String,
    #[serde(rename = "windowId")]
    pub window_id: String,
    pub filename: String,
    #[serde(rename = "mimeType")]
    pub mime_type: String,
    pub data: String,
}

/// host -> iPhone. Sent after the image was written to disk and the path was pasted.
#[derive(Debug, Clone, Serialize)]
pub struct ImageUploadAckMessage {
    #[serde(rename = "type")]
    pub type_: String,
    #[serde(rename = "imageId")]
    pub image_id: String,
    #[serde(rename = "savedPath")]
    pub saved_path: String,
}

impl ImageUploadAckMessage {
    pub fn new(image_id: String, saved_path: String) -> Self {
        Self { type_: "image_upload_ack".into(), image_id, saved_path }
    }
}

/// host -> iPhone. Sent on any image-upload failure (decode, unknown window,
/// disk write, path traversal, etc.).
#[derive(Debug, Clone, Serialize)]
pub struct ImageUploadErrorMessage {
    #[serde(rename = "type")]
    pub type_: String,
    #[serde(rename = "imageId")]
    pub image_id: String,
    pub reason: String,
}

impl ImageUploadErrorMessage {
    pub fn new(image_id: String, reason: String) -> Self {
        Self { type_: "image_upload_error".into(), image_id, reason }
    }
}

// ---------------------------------------------------------------------------
// Attach-existing-iTerm flow (iTerm-specific — parse-only on Linux so the
// "unknown message type" path doesn't fire when an iOS build sends one)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Deserialize)]
pub struct ScanITermWindowsMessage {}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct ITermWindowInfo {
    #[serde(rename = "windowNumber")]
    pub window_number: i64,
    pub title: String,
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub cwd: String,
    #[serde(rename = "isAlreadyTracked")]
    pub is_already_tracked: bool,
    #[serde(rename = "isMiniaturized")]
    pub is_miniaturized: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ITermWindowListMessage {
    #[serde(rename = "type", default = "ITermWindowListMessage::default_type")]
    pub type_: String,
    pub windows: Vec<ITermWindowInfo>,
}

impl ITermWindowListMessage {
    fn default_type() -> String { "iterm_window_list".into() }
    pub fn new(windows: Vec<ITermWindowInfo>) -> Self {
        Self { type_: "iterm_window_list".into(), windows }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct AttachITermWindowMessage {
    #[serde(rename = "windowNumber")]
    pub window_number: i64,
    #[serde(rename = "sessionId")]
    pub session_id: String,
}

// ---------------------------------------------------------------------------
// Push notifications (iPhone-side registration; APNs delivery handled
// in services/push_notifications.rs if the APNs port lands)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Deserialize)]
pub struct RegisterPushDeviceMessage {
    #[serde(rename = "deviceToken")]
    pub device_token: String,
    pub environment: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PushPreferencesMessage {
    #[serde(rename = "type", default = "PushPreferencesMessage::default_type")]
    pub type_: String,
    #[serde(rename = "deviceToken")]
    pub device_token: String,
    pub paused: bool,
    #[serde(rename = "quietHoursStart", default)]
    pub quiet_hours_start: Option<i32>,
    #[serde(rename = "quietHoursEnd", default)]
    pub quiet_hours_end: Option<i32>,
    pub sound: bool,
    #[serde(rename = "foregroundBanner")]
    pub foreground_banner: bool,
    /// Master toggle for APNs banner alerts. When false, the host skips the
    /// APNs push entirely; Live Activities still update via WebSocket.
    /// Optional in the wire format for older iOS clients.
    #[serde(rename = "bannerEnabled", default, skip_serializing_if = "Option::is_none")]
    pub banner_enabled: Option<bool>,
    /// IANA TZ identifier (e.g. "America/Phoenix") for the phone — host uses
    /// it to evaluate quiet hours against the user's clock, not its own.
    /// Optional for older iOS clients.
    #[serde(rename = "timeZone", default, skip_serializing_if = "Option::is_none")]
    pub time_zone: Option<String>,
}

impl PushPreferencesMessage {
    fn default_type() -> String { "push_preferences".into() }
}

// ---------------------------------------------------------------------------
// Preferences backup (phone-prefs mirrored to host so reinstalls survive)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct PreferencesSnapshot {
    #[serde(default, rename = "enabledQuickButtons", skip_serializing_if = "Option::is_none")]
    pub enabled_quick_buttons: Option<String>,
    #[serde(default, rename = "tintContentBorder", skip_serializing_if = "Option::is_none")]
    pub tint_content_border: Option<bool>,
    #[serde(default, rename = "contentZoomLevel", skip_serializing_if = "Option::is_none")]
    pub content_zoom_level: Option<i32>,
    #[serde(default, rename = "terminalHeightFraction", skip_serializing_if = "Option::is_none")]
    pub terminal_height_fraction: Option<f64>,
    #[serde(default, rename = "terminalWidthFraction", skip_serializing_if = "Option::is_none")]
    pub terminal_width_fraction: Option<f64>,
    #[serde(default, rename = "pushPaused", skip_serializing_if = "Option::is_none")]
    pub push_paused: Option<bool>,
    #[serde(default, rename = "pushBannerEnabled", skip_serializing_if = "Option::is_none")]
    pub push_banner_enabled: Option<bool>,
    #[serde(default, rename = "pushSound", skip_serializing_if = "Option::is_none")]
    pub push_sound: Option<bool>,
    #[serde(default, rename = "pushForegroundBanner", skip_serializing_if = "Option::is_none")]
    pub push_foreground_banner: Option<bool>,
    #[serde(default, rename = "pushQuietHoursEnabled", skip_serializing_if = "Option::is_none")]
    pub push_quiet_hours_enabled: Option<bool>,
    #[serde(default, rename = "pushQuietHoursStart", skip_serializing_if = "Option::is_none")]
    pub push_quiet_hours_start: Option<i32>,
    #[serde(default, rename = "pushQuietHoursEnd", skip_serializing_if = "Option::is_none")]
    pub push_quiet_hours_end: Option<i32>,
    #[serde(default, rename = "liveActivitiesEnabled", skip_serializing_if = "Option::is_none")]
    pub live_activities_enabled: Option<bool>,
    #[serde(default, rename = "ttsEnabled", skip_serializing_if = "Option::is_none")]
    pub tts_enabled: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PreferenceSnapshotMessage {
    #[serde(rename = "deviceID")]
    pub device_id: String,
    pub preferences: PreferencesSnapshot,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PreferenceRequestMessage {
    #[serde(rename = "deviceID")]
    pub device_id: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct PreferenceRestoreMessage {
    #[serde(rename = "type")]
    pub type_: String,
    pub preferences: PreferencesSnapshot,
}

impl PreferenceRestoreMessage {
    pub fn new(preferences: PreferencesSnapshot) -> Self {
        Self { type_: "preferences_restore".into(), preferences }
    }
}

// ---------------------------------------------------------------------------
// Host permissions (kept under the "mac_permissions" wire name for iOS-app
// compat — Linux fills the booleans from its own probes: accessibility ↔
// input-injection capability, screenRecording ↔ screencast portal grant,
// appleEvents always true on Linux since N/A).
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MacSettingsPane {
    #[serde(rename = "accessibility")]
    Accessibility,
    #[serde(rename = "automation")]
    Automation,
    #[serde(rename = "screenRecording")]
    ScreenRecording,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MacPermissionsMessage {
    #[serde(rename = "type", default = "MacPermissionsMessage::default_type")]
    pub type_: String,
    pub accessibility: bool,
    #[serde(rename = "appleEvents")]
    pub apple_events: bool,
    #[serde(rename = "screenRecording")]
    pub screen_recording: bool,
}

impl MacPermissionsMessage {
    fn default_type() -> String { "mac_permissions".into() }

    pub fn new(accessibility: bool, apple_events: bool, screen_recording: bool) -> Self {
        Self {
            type_: "mac_permissions".into(),
            accessibility,
            apple_events,
            screen_recording,
        }
    }

    pub fn denied_count(&self) -> usize {
        usize::from(!self.accessibility) + usize::from(!self.apple_events) + usize::from(!self.screen_recording)
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct OpenMacSettingsPaneMessage {
    pub pane: MacSettingsPane,
}

// ---------------------------------------------------------------------------
// Whisper PTT — audio chunks in, transcripts/status out
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct AudioChunkMessage {
    #[serde(rename = "type", default = "AudioChunkMessage::default_type")]
    pub type_: String,
    #[serde(rename = "sessionId")]
    pub session_id: uuid::Uuid,
    pub seq: i64,
    #[serde(rename = "pcmBase64")]
    pub pcm_base64: String,
    #[serde(rename = "isFinal")]
    pub is_final: bool,
}

impl AudioChunkMessage {
    fn default_type() -> String { "audio_chunk".into() }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranscriptResultMessage {
    #[serde(rename = "type", default = "TranscriptResultMessage::default_type")]
    pub type_: String,
    #[serde(rename = "sessionId")]
    pub session_id: uuid::Uuid,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl TranscriptResultMessage {
    fn default_type() -> String { "transcript_result".into() }

    pub fn ok(session_id: uuid::Uuid, text: String) -> Self {
        Self { type_: "transcript_result".into(), session_id, text, error: None }
    }

    pub fn err(session_id: uuid::Uuid, error: String) -> Self {
        Self { type_: "transcript_result".into(), session_id, text: String::new(), error: Some(error) }
    }
}

/// Whisper model lifecycle. Tagged-enum on the wire to match Swift's
/// `WhisperState` Codable layout: `{ "tag": "downloading", "progress": 0.5 }`.
#[derive(Debug, Clone, PartialEq)]
pub enum WhisperState {
    Preparing,
    Downloading { progress: f64 },
    Ready,
    Failed { message: String },
}

impl Serialize for WhisperState {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let mut m = s.serialize_map(None)?;
        match self {
            WhisperState::Preparing => { m.serialize_entry("tag", "preparing")?; }
            WhisperState::Downloading { progress } => {
                m.serialize_entry("tag", "downloading")?;
                m.serialize_entry("progress", progress)?;
            }
            WhisperState::Ready => { m.serialize_entry("tag", "ready")?; }
            WhisperState::Failed { message } => {
                m.serialize_entry("tag", "failed")?;
                m.serialize_entry("message", message)?;
            }
        }
        m.end()
    }
}

impl<'de> Deserialize<'de> for WhisperState {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Raw {
            tag: String,
            #[serde(default)]
            progress: Option<f64>,
            #[serde(default)]
            message: Option<String>,
        }
        let raw = Raw::deserialize(d)?;
        match raw.tag.as_str() {
            "preparing" => Ok(WhisperState::Preparing),
            "downloading" => Ok(WhisperState::Downloading {
                progress: raw.progress.unwrap_or(0.0),
            }),
            "ready" => Ok(WhisperState::Ready),
            "failed" => Ok(WhisperState::Failed {
                message: raw.message.unwrap_or_default(),
            }),
            other => Err(serde::de::Error::custom(format!("unknown whisper tag '{other}'"))),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WhisperStatusMessage {
    #[serde(rename = "type", default = "WhisperStatusMessage::default_type")]
    pub type_: String,
    pub state: WhisperState,
}

impl WhisperStatusMessage {
    fn default_type() -> String { "whisper_status".into() }

    pub fn new(state: WhisperState) -> Self {
        Self { type_: "whisper_status".into(), state }
    }
}

// ---------------------------------------------------------------------------
// Encoding helpers — JSON with sorted keys to match Swift's sortedKeys output
// ---------------------------------------------------------------------------

pub fn encode_message<T: Serialize>(msg: &T) -> Option<String> {
    // serde_json sorts keys by default when the struct fields are in order.
    // For guaranteed sorted keys we serialize to Value first.
    let value = serde_json::to_value(msg).ok()?;
    serde_json::to_string(&value).ok()
}

pub fn message_type(data: &str) -> Option<String> {
    let envelope: MessageEnvelope = serde_json::from_str(data).ok()?;
    Some(envelope.type_)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn dict(s: &str) -> Value {
        serde_json::from_str(s).unwrap()
    }

    // -- ClaudeMode ----------------------------------------------------------

    #[test]
    fn claude_mode_raw_values() {
        assert_eq!(ClaudeMode::Normal.as_str(), "normal");
        assert_eq!(ClaudeMode::Plan.as_str(), "plan");
        assert_eq!(ClaudeMode::AutoAccept.as_str(), "autoAccept");
    }

    #[test]
    fn claude_mode_serializes_to_raw_string() {
        let s = serde_json::to_string(&ClaudeMode::AutoAccept).unwrap();
        assert_eq!(s, "\"autoAccept\"");
    }

    #[test]
    fn shift_tab_presses_zero_when_already_on_target() {
        for m in ClaudeMode::CYCLE {
            assert_eq!(ClaudeMode::shift_tab_presses(m, m), 0);
        }
    }

    #[test]
    fn shift_tab_presses_forward_through_cycle() {
        // normal → autoAccept → plan → normal
        assert_eq!(ClaudeMode::shift_tab_presses(ClaudeMode::Normal, ClaudeMode::AutoAccept), 1);
        assert_eq!(ClaudeMode::shift_tab_presses(ClaudeMode::AutoAccept, ClaudeMode::Plan), 1);
        assert_eq!(ClaudeMode::shift_tab_presses(ClaudeMode::Plan, ClaudeMode::Normal), 1);
    }

    #[test]
    fn shift_tab_presses_wraps_around() {
        assert_eq!(ClaudeMode::shift_tab_presses(ClaudeMode::Normal, ClaudeMode::Plan), 2);
        assert_eq!(ClaudeMode::shift_tab_presses(ClaudeMode::AutoAccept, ClaudeMode::Normal), 2);
        assert_eq!(ClaudeMode::shift_tab_presses(ClaudeMode::Plan, ClaudeMode::AutoAccept), 2);
    }

    #[test]
    fn shift_tab_presses_always_in_range() {
        for from in ClaudeMode::CYCLE {
            for to in ClaudeMode::CYCLE {
                let n = ClaudeMode::shift_tab_presses(from, to);
                assert!(n <= 2, "got {n} for {from:?} -> {to:?}");
            }
        }
    }

    // -- WindowState backwards compat ---------------------------------------

    #[test]
    fn window_state_decodes_without_is_thinking_or_claude_mode() {
        let json = r##"{
            "id":"w1","name":"Terminal","app":"Terminal","enabled":true,
            "frame":{"x":0,"y":0,"width":1,"height":1},
            "state":"neutral","color":"#FFFFFF"
        }"##;
        let s: WindowState = serde_json::from_str(json).unwrap();
        assert!(!s.is_thinking);
        assert!(s.claude_mode.is_none());
        assert!(s.folder.is_none());
    }

    #[test]
    fn window_state_round_trip_with_claude_mode() {
        let original = WindowState {
            id: "w3".into(), name: "claude".into(), app: "iTerm2".into(),
            folder: Some("Quip".into()), enabled: true,
            frame: super::super::types::WindowFrame { x: 0.0, y: 0.0, width: 1.0, height: 1.0 },
            state: "neutral".into(), color: "#00FF00".into(),
            is_thinking: true, claude_mode: Some("plan".into()),
        };
        let json = serde_json::to_string(&original).unwrap();
        let restored: WindowState = serde_json::from_str(&json).unwrap();
        assert_eq!(restored, original);
    }

    // -- TerminalContent ----------------------------------------------------

    #[test]
    fn terminal_content_round_trip_with_urls_and_screenshot() {
        let msg = TerminalContentMessage::with_screenshot(
            "w1".into(), "$ ls\n".into(), "iVBORw0KGgo".into(),
        ).with_urls(vec!["https://example.com".into()]);
        let json = serde_json::to_string(&msg).unwrap();
        let restored: TerminalContentMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(restored.window_id, "w1");
        assert_eq!(restored.screenshot.as_deref(), Some("iVBORw0KGgo"));
        assert_eq!(restored.urls.unwrap(), vec!["https://example.com"]);
    }

    #[test]
    fn terminal_content_omits_optional_fields_when_unset() {
        let msg = TerminalContentMessage::new("w1".into(), "x".into());
        let json = serde_json::to_string(&msg).unwrap();
        assert!(!json.contains("screenshot"));
        assert!(!json.contains("urls"));
    }

    // -- Image upload --------------------------------------------------------

    #[test]
    fn image_upload_decodes() {
        let json = r#"{"type":"image_upload","imageId":"img1","windowId":"w1","filename":"a.png","mimeType":"image/png","data":"AAAA"}"#;
        let msg: ImageUploadMessage = serde_json::from_str(json).unwrap();
        assert_eq!(msg.image_id, "img1");
        assert_eq!(msg.window_id, "w1");
        assert_eq!(msg.filename, "a.png");
        assert_eq!(msg.mime_type, "image/png");
        assert_eq!(msg.data, "AAAA");
    }

    #[test]
    fn image_upload_ack_encodes() {
        let msg = ImageUploadAckMessage::new("img1".into(), "/tmp/uploads/a.png".into());
        let v = dict(&serde_json::to_string(&msg).unwrap());
        assert_eq!(v["type"], "image_upload_ack");
        assert_eq!(v["imageId"], "img1");
        assert_eq!(v["savedPath"], "/tmp/uploads/a.png");
    }

    #[test]
    fn image_upload_error_encodes() {
        let msg = ImageUploadErrorMessage::new("img1".into(), "decode failed".into());
        let v = dict(&serde_json::to_string(&msg).unwrap());
        assert_eq!(v["type"], "image_upload_error");
        assert_eq!(v["reason"], "decode failed");
    }

    // -- Arrange / Spawn / Project ------------------------------------------

    #[test]
    fn arrange_windows_round_trip() {
        let msg = ArrangeWindowsMessage { type_: "arrange_windows".into(), layout: "horizontal".into() };
        let json = serde_json::to_string(&msg).unwrap();
        let restored: ArrangeWindowsMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(restored.type_, "arrange_windows");
        assert_eq!(restored.layout, "horizontal");
    }

    #[test]
    fn spawn_window_decodes() {
        let m: SpawnWindowMessage = serde_json::from_str(r#"{"type":"spawn_window","directory":"/tmp"}"#).unwrap();
        assert_eq!(m.directory, "/tmp");
    }

    #[test]
    fn project_directories_encodes() {
        let m = ProjectDirectoriesMessage::new(vec!["/a".into(), "/b".into()]);
        let v = dict(&serde_json::to_string(&m).unwrap());
        assert_eq!(v["type"], "project_directories");
        assert_eq!(v["directories"][0], "/a");
        assert_eq!(v["directories"][1], "/b");
    }

    #[test]
    fn error_message_encodes() {
        let v = dict(&serde_json::to_string(&ErrorMessage::new("nope".into())).unwrap());
        assert_eq!(v["type"], "error");
        assert_eq!(v["reason"], "nope");
    }

    // -- iTerm scan list (parse-only) ---------------------------------------

    #[test]
    fn iterm_window_list_round_trip() {
        let infos = vec![
            ITermWindowInfo {
                window_number: 1, title: "claude".into(), session_id: "A".into(),
                cwd: "/Users/dev/proj".into(), is_already_tracked: false, is_miniaturized: false,
            },
            ITermWindowInfo {
                window_number: 2, title: "zsh".into(), session_id: "B".into(),
                cwd: "/tmp".into(), is_already_tracked: true, is_miniaturized: true,
            },
        ];
        let msg = ITermWindowListMessage::new(infos.clone());
        let json = serde_json::to_string(&msg).unwrap();
        let decoded: ITermWindowListMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.type_, "iterm_window_list");
        assert_eq!(decoded.windows, infos);
    }

    #[test]
    fn attach_iterm_window_decodes() {
        let m: AttachITermWindowMessage = serde_json::from_str(
            r#"{"type":"attach_iterm_window","windowNumber":4271,"sessionId":"ABC-DEF"}"#
        ).unwrap();
        assert_eq!(m.window_number, 4271);
        assert_eq!(m.session_id, "ABC-DEF");
    }

    // -- Push preferences ---------------------------------------------------

    #[test]
    fn push_preferences_round_trip_with_quiet_hours() {
        let msg = PushPreferencesMessage {
            type_: "push_preferences".into(),
            device_token: "TKN".into(), paused: true,
            quiet_hours_start: Some(22), quiet_hours_end: Some(7),
            sound: false, foreground_banner: true,
            banner_enabled: None, time_zone: None,
        };
        let json = serde_json::to_string(&msg).unwrap();
        let decoded: PushPreferencesMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.paused, true);
        assert_eq!(decoded.quiet_hours_start, Some(22));
        assert_eq!(decoded.quiet_hours_end, Some(7));
    }

    #[test]
    fn push_preferences_carries_time_zone_and_banner_enabled() {
        let json = r#"{"type":"push_preferences","deviceToken":"TKN","paused":false,
            "quietHoursStart":22,"quietHoursEnd":7,"sound":true,"foregroundBanner":false,
            "bannerEnabled":true,"timeZone":"America/Phoenix"}"#;
        let m: PushPreferencesMessage = serde_json::from_str(json).unwrap();
        assert_eq!(m.banner_enabled, Some(true));
        assert_eq!(m.time_zone.as_deref(), Some("America/Phoenix"));
    }

    #[test]
    fn push_preferences_legacy_decodes_without_optional_fields() {
        let json = r#"{"type":"push_preferences","deviceToken":"TKN","paused":false,
            "sound":true,"foregroundBanner":false}"#;
        let m: PushPreferencesMessage = serde_json::from_str(json).unwrap();
        assert!(m.banner_enabled.is_none());
        assert!(m.time_zone.is_none());
        assert!(m.quiet_hours_start.is_none());
    }

    #[test]
    fn register_push_device_decodes() {
        let json = r#"{"type":"register_push_device","deviceToken":"ABCD","environment":"development"}"#;
        let m: RegisterPushDeviceMessage = serde_json::from_str(json).unwrap();
        assert_eq!(m.device_token, "ABCD");
        assert_eq!(m.environment, "development");
    }

    // -- Mac permissions ----------------------------------------------------

    #[test]
    fn mac_permissions_encodes() {
        let msg = MacPermissionsMessage::new(true, false, true);
        let v = dict(&serde_json::to_string(&msg).unwrap());
        assert_eq!(v["type"], "mac_permissions");
        assert_eq!(v["accessibility"], true);
        assert_eq!(v["appleEvents"], false);
        assert_eq!(v["screenRecording"], true);
    }

    #[test]
    fn mac_permissions_denied_count() {
        assert_eq!(MacPermissionsMessage::new(true, true, true).denied_count(), 0);
        assert_eq!(MacPermissionsMessage::new(false, true, true).denied_count(), 1);
        assert_eq!(MacPermissionsMessage::new(false, false, false).denied_count(), 3);
    }

    #[test]
    fn open_mac_settings_pane_decodes_all_cases() {
        for (raw, expected) in &[
            ("accessibility", MacSettingsPane::Accessibility),
            ("automation", MacSettingsPane::Automation),
            ("screenRecording", MacSettingsPane::ScreenRecording),
        ] {
            let json = format!(r#"{{"type":"open_mac_settings_pane","pane":"{raw}"}}"#);
            let m: OpenMacSettingsPaneMessage = serde_json::from_str(&json).unwrap();
            assert_eq!(m.pane, *expected);
        }
    }

    // -- Preferences backup -------------------------------------------------

    #[test]
    fn preferences_snapshot_round_trip() {
        let snap = PreferencesSnapshot {
            enabled_quick_buttons: Some("ctrl_c,ctrl_u".into()),
            content_zoom_level: Some(2),
            push_paused: Some(true),
            push_quiet_hours_start: Some(22),
            push_quiet_hours_end: Some(7),
            live_activities_enabled: Some(true),
            ..Default::default()
        };
        let json = serde_json::to_string(&snap).unwrap();
        let restored: PreferencesSnapshot = serde_json::from_str(&json).unwrap();
        assert_eq!(restored, snap);
    }

    #[test]
    fn preferences_snapshot_omits_unset_fields() {
        let snap = PreferencesSnapshot::default();
        let json = serde_json::to_string(&snap).unwrap();
        assert_eq!(json, "{}");
    }

    // -- Whisper PTT --------------------------------------------------------

    #[test]
    fn audio_chunk_round_trip() {
        let id = uuid::Uuid::new_v4();
        let msg = AudioChunkMessage {
            type_: "audio_chunk".into(), session_id: id, seq: 7,
            pcm_base64: "AQIDBA==".into(), is_final: false,
        };
        let json = serde_json::to_string(&msg).unwrap();
        let v = dict(&json);
        assert_eq!(v["type"], "audio_chunk");
        assert_eq!(v["seq"], 7);
        assert_eq!(v["isFinal"], false);
        let decoded: AudioChunkMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.session_id, id);
        assert_eq!(decoded.seq, 7);
        assert_eq!(decoded.pcm_base64, "AQIDBA==");
    }

    #[test]
    fn transcript_result_ok_round_trip() {
        let id = uuid::Uuid::new_v4();
        let msg = TranscriptResultMessage::ok(id, "hello".into());
        let json = serde_json::to_string(&msg).unwrap();
        let decoded: TranscriptResultMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.session_id, id);
        assert_eq!(decoded.text, "hello");
        assert!(decoded.error.is_none());
    }

    #[test]
    fn transcript_result_err_round_trip() {
        let id = uuid::Uuid::new_v4();
        let msg = TranscriptResultMessage::err(id, "model failed".into());
        let json = serde_json::to_string(&msg).unwrap();
        let decoded: TranscriptResultMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.text, "");
        assert_eq!(decoded.error.as_deref(), Some("model failed"));
    }

    #[test]
    fn whisper_status_ready_round_trip() {
        let msg = WhisperStatusMessage::new(WhisperState::Ready);
        let json = serde_json::to_string(&msg).unwrap();
        let v = dict(&json);
        assert_eq!(v["state"]["tag"], "ready");
        let decoded: WhisperStatusMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.state, WhisperState::Ready);
    }

    #[test]
    fn whisper_status_downloading_round_trip() {
        let msg = WhisperStatusMessage::new(WhisperState::Downloading { progress: 0.42 });
        let json = serde_json::to_string(&msg).unwrap();
        let v = dict(&json);
        assert_eq!(v["state"]["tag"], "downloading");
        assert!((v["state"]["progress"].as_f64().unwrap() - 0.42).abs() < 1e-6);
        let decoded: WhisperStatusMessage = serde_json::from_str(&json).unwrap();
        match decoded.state {
            WhisperState::Downloading { progress } => assert!((progress - 0.42).abs() < 1e-6),
            _ => panic!("expected Downloading"),
        }
    }

    #[test]
    fn whisper_status_failed_round_trip() {
        let msg = WhisperStatusMessage::new(WhisperState::Failed { message: "no network".into() });
        let json = serde_json::to_string(&msg).unwrap();
        let decoded: WhisperStatusMessage = serde_json::from_str(&json).unwrap();
        match decoded.state {
            WhisperState::Failed { message } => assert_eq!(message, "no network"),
            _ => panic!("expected Failed"),
        }
    }

    // -- Envelope / message_type extraction ---------------------------------

    #[test]
    fn message_type_extraction() {
        let cases: &[(&str, &str)] = &[
            (r#"{"type":"image_upload","imageId":"x","windowId":"y","filename":"a","mimeType":"m","data":"d"}"#, "image_upload"),
            (r#"{"type":"audio_chunk","sessionId":"550e8400-e29b-41d4-a716-446655440000","seq":0,"pcmBase64":"","isFinal":true}"#, "audio_chunk"),
            (r#"{"type":"arrange_windows","layout":"horizontal"}"#, "arrange_windows"),
            (r#"{"type":"spawn_window","directory":"/tmp"}"#, "spawn_window"),
            (r#"{"type":"register_push_device","deviceToken":"x","environment":"y"}"#, "register_push_device"),
            (r#"{"type":"open_mac_settings_pane","pane":"accessibility"}"#, "open_mac_settings_pane"),
            (r#"{"type":"future_unknown","x":1}"#, "future_unknown"),
        ];
        for (json, expected) in cases {
            assert_eq!(message_type(json).as_deref(), Some(*expected), "for {json}");
        }
    }
}
