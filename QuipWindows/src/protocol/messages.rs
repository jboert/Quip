//! Phase-1 messages (spec 3.1-3.3).
//!
//! Started as a copy of `QuipLinux/src/protocol/messages.rs` and reconciled,
//! field by field, against `Shared/MessageProtocol.swift` (the truth: where the
//! two disagree the Mac wins, spec 2). Swift's synthesized `Encodable` omits a
//! nil optional rather than writing `null`, so every optional here is
//! `skip_serializing_if = "Option::is_none"`.
//!
//! | Message | Dir | Change vs the QuipLinux copy |
//! |---|---|---|
//! | `auth` | phone→host | unchanged (`pin`) |
//! | `auth_result` | host→phone | unchanged shape; the host now also sends `success:false,error:"auth_required"` the moment the socket is up (the 1.6.0 phone waits for it before sending its PIN, `QuipiOS/Services/WebSocketClient.swift`; Linux never sent it) |
//! | `device_identity` | host→phone | + `localURLs` (optional); `deviceKind` is `"windows"` |
//! | `layout_update` | host→phone | + `displays`, `spanAspect`, `spaces` (all optional; `spaces` never sent in phase 1) |
//! | `WindowState` | in `layout_update` | + `cliKind`, `targetKind`, `displayID`, `spaceID`, `isPinned`, `isMinimized`, `project`; optionals decode leniently (`try?` on the Mac: a wrong type reads as absent) |
//! | `DisplayState` | in `layout_update` | new (from `Shared/DisplayGeometry.swift`) |
//! | `frontmost_changed` | host→phone | new; `windowId` omitted (not `null`) when the foreground window is untracked, as Swift encodes nil |
//! | `heartbeat` | host→phone | new (`seq` Int, `ts` Double seconds since 1970) |
//! | `heartbeat_ack` | phone→host | new (`seq`) |
//! | `send_text_ack` | host→phone | new (`messageId` UUID, `injectMs`, `totalMs`, `path`) |
//! | `error` | host→phone | + `messageId` (optional, US-115) |
//! | `state_change` | host→phone | unchanged (not sent in phase 1) |
//! | `select_window` | phone→host | unchanged |
//! | `send_text` | phone→host | + `messageId` (optional UUID: an invalid string fails the whole message, as on the Mac), + `raiseWindow` (optional, ignored on Windows) |
//! | `quick_action` | phone→host | + `messageId`, + `promptFingerprint` (both optional; fingerprint ignored in phase 1) |
//! | `arrange_windows` | phone→host | `layout` is the closed `ArrangeLayout` enum, was a free `String` |
//! | `minimize_window` | phone→host | new (`windowId`, `messageId`) |
//! | `close_window` | phone→host | + `messageId` |
//! | `phone_log` | phone→host | new (`lines`) |
//! | `preferences_snapshot` | phone→host | `preferences` kept as raw JSON, was a fixed struct that dropped every key the 1.3.3 copy did not know |
//! | `preferences_request` | phone→host | unchanged (`deviceID`) |
//! | `preferences_restore` | host→phone | + `deviceID` (optional) |
//! | `request_content` | phone→host | new (`windowId`); the phone asks every 2 s for the selected window |
//! | `terminal_content` | host→phone | new; phase 1 answers `request_content` with a fixed "not available" text so the phone stops saying "No reply from the Mac" |
//!
//! Dropped from the copy (phase 2 or never on Windows, spec 12): real terminal
//! content (screen text, screenshot, URLs, autosuggest), output delta, TTS, image upload, iTerm attach, push, Mac
//! permissions, Whisper, spawn / duplicate, project directories. Their types
//! still arrive and are ignored by `decode_incoming` as unknown.

use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;

use super::types::{ArrangeLayout, CliKind, WindowFrame, WireUuid};

// ---------------------------------------------------------------------------
// Host -> phone
// ---------------------------------------------------------------------------

/// `AuthResultMessage`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AuthResult {
    #[serde(rename = "type")]
    pub type_: String,
    pub success: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl AuthResult {
    /// The error string the phone treats as "server is up and wants a PIN"
    /// (`WebSocketClient.swift`: `if msg.error == "auth_required"`).
    pub const AUTH_REQUIRED: &'static str = "auth_required";

    pub fn success() -> Self {
        Self { type_: "auth_result".into(), success: true, error: None }
    }

    pub fn failure(error: impl Into<String>) -> Self {
        Self { type_: "auth_result".into(), success: false, error: Some(error.into()) }
    }

    pub fn auth_required() -> Self {
        Self::failure(Self::AUTH_REQUIRED)
    }
}

/// `DeviceIdentityMessage`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeviceIdentity {
    #[serde(rename = "type")]
    pub type_: String,
    #[serde(rename = "deviceID")]
    pub device_id: String,
    #[serde(rename = "deviceKind")]
    pub device_kind: String,
    #[serde(rename = "displayName")]
    pub display_name: String,
    #[serde(rename = "localURLs", default, skip_serializing_if = "Option::is_none")]
    pub local_urls: Option<Vec<String>>,
}

impl DeviceIdentity {
    /// Spec 2: the phone maps an unknown kind to `BackendKind.unknown`.
    pub const KIND_WINDOWS: &'static str = "windows";

    pub fn windows(device_id: String, display_name: String, local_urls: Vec<String>) -> Self {
        Self {
            type_: "device_identity".into(),
            device_id,
            device_kind: Self::KIND_WINDOWS.into(),
            display_name,
            local_urls: Some(local_urls),
        }
    }
}

/// `DisplayState` in `Shared/DisplayGeometry.swift`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DisplayState {
    pub id: String,
    pub name: String,
    #[serde(rename = "isPrimary")]
    pub is_primary: bool,
    pub aspect: f64,
    #[serde(rename = "spanFrame")]
    pub span_frame: WindowFrame,
}

/// `SpaceState`. Never sent in phase 1 (virtual desktops are phase 2); kept so
/// a Mac-shaped `layout_update` decodes.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SpaceState {
    pub id: String,
    pub name: String,
    #[serde(rename = "isCurrent")]
    pub is_current: bool,
}

/// `LayoutUpdate`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LayoutUpdate {
    #[serde(rename = "type")]
    pub type_: String,
    /// The PRIMARY display's name. The phone uses it as a same-host identity
    /// signal, so it must not change when focus moves (spec 3.4).
    pub monitor: String,
    #[serde(rename = "screenAspect", default, skip_serializing_if = "Option::is_none")]
    pub screen_aspect: Option<f64>,
    pub windows: Vec<WindowState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub displays: Option<Vec<DisplayState>>,
    #[serde(rename = "spanAspect", default, skip_serializing_if = "Option::is_none")]
    pub span_aspect: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spaces: Option<Vec<SpaceState>>,
}

impl LayoutUpdate {
    pub fn new(
        monitor: String,
        screen_aspect: Option<f64>,
        windows: Vec<WindowState>,
        displays: Option<Vec<DisplayState>>,
        span_aspect: Option<f64>,
    ) -> Self {
        Self { type_: "layout_update".into(), monitor, screen_aspect, windows, displays, span_aspect, spaces: None }
    }
}

/// Swift's `try? c.decode(T.self, forKey:)`: absent, `null` or the wrong type
/// all read as nil instead of failing the whole `WindowState`.
fn lenient<'de, D, T>(d: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: serde::de::DeserializeOwned,
{
    let v = Option::<Value>::deserialize(d)?;
    Ok(v.and_then(|v| serde_json::from_value(v).ok()))
}

/// `(try? c.decode(Bool.self, forKey:)) ?? false`.
fn lenient_bool<'de, D: Deserializer<'de>>(d: D) -> Result<bool, D::Error> {
    Ok(lenient::<D, bool>(d)?.unwrap_or(false))
}

/// `WindowState`. Encoding follows Swift's synthesized `Encodable`; decoding
/// follows the hand-written `init(from:)` (lenient optionals).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WindowState {
    pub id: String,
    pub name: String,
    pub app: String,
    #[serde(default, deserialize_with = "lenient", skip_serializing_if = "Option::is_none")]
    pub folder: Option<String>,
    pub enabled: bool,
    pub frame: WindowFrame,
    pub state: String,
    pub color: String,
    #[serde(rename = "isThinking", default, deserialize_with = "lenient_bool")]
    pub is_thinking: bool,
    #[serde(rename = "claudeMode", default, deserialize_with = "lenient", skip_serializing_if = "Option::is_none")]
    pub claude_mode: Option<String>,
    #[serde(rename = "cliKind", default, deserialize_with = "lenient", skip_serializing_if = "Option::is_none")]
    pub cli_kind: Option<CliKind>,
    #[serde(rename = "targetKind", default, deserialize_with = "lenient", skip_serializing_if = "Option::is_none")]
    pub target_kind: Option<String>,
    #[serde(rename = "displayID", default, deserialize_with = "lenient", skip_serializing_if = "Option::is_none")]
    pub display_id: Option<String>,
    #[serde(rename = "spaceID", default, deserialize_with = "lenient", skip_serializing_if = "Option::is_none")]
    pub space_id: Option<String>,
    #[serde(rename = "isPinned", default, deserialize_with = "lenient_bool")]
    pub is_pinned: bool,
    #[serde(rename = "isMinimized", default, deserialize_with = "lenient_bool")]
    pub is_minimized: bool,
    #[serde(default, deserialize_with = "lenient", skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
}

/// `FrontmostChangedMessage`. `windowId: nil` is OMITTED on the wire (Swift
/// synthesized encoding); the phone reads absent and `null` alike.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FrontmostChanged {
    #[serde(rename = "type")]
    pub type_: String,
    #[serde(rename = "windowId", default, skip_serializing_if = "Option::is_none")]
    pub window_id: Option<String>,
}

impl FrontmostChanged {
    pub fn new(window_id: Option<String>) -> Self {
        Self { type_: "frontmost_changed".into(), window_id }
    }
}

/// `HeartbeatMessage`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Heartbeat {
    #[serde(rename = "type")]
    pub type_: String,
    pub seq: i64,
    pub ts: f64,
}

impl Heartbeat {
    pub fn new(seq: i64, ts: f64) -> Self {
        Self { type_: "heartbeat".into(), seq, ts }
    }
}

/// `SendTextAckMessage`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SendTextAck {
    #[serde(rename = "type")]
    pub type_: String,
    #[serde(rename = "messageId")]
    pub message_id: WireUuid,
    #[serde(rename = "injectMs")]
    pub inject_ms: i64,
    #[serde(rename = "totalMs")]
    pub total_ms: i64,
    pub path: String,
}

impl SendTextAck {
    /// Windows types every send as keystrokes: the Mac's `sendText` route.
    pub const PATH_SEND_TEXT: &'static str = "sendText";

    pub fn new(message_id: WireUuid, inject_ms: i64, total_ms: i64) -> Self {
        Self { type_: "send_text_ack".into(), message_id, inject_ms, total_ms, path: Self::PATH_SEND_TEXT.into() }
    }
}

/// `ErrorMessage`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ErrorMessage {
    #[serde(rename = "type")]
    pub type_: String,
    pub reason: String,
    #[serde(rename = "messageId", default, skip_serializing_if = "Option::is_none")]
    pub message_id: Option<WireUuid>,
}

impl ErrorMessage {
    pub fn new(reason: impl Into<String>, message_id: Option<WireUuid>) -> Self {
        Self { type_: "error".into(), reason: reason.into(), message_id }
    }
}

/// `TerminalContentMessage` (`Shared/MessageProtocol.swift`). The Swift
/// encoder always writes `type`, `windowId`, `content` and `hasAutosuggest`;
/// `screenshot`, `urls` and `autosuggest` are optional and never sent here.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TerminalContent {
    #[serde(rename = "type")]
    pub type_: String,
    #[serde(rename = "windowId")]
    pub window_id: String,
    pub content: String,
    #[serde(rename = "hasAutosuggest", default)]
    pub has_autosuggest: bool,
}

impl TerminalContent {
    /// Phase 1 has no way to read a console's text (spec 12).
    pub const NOT_AVAILABLE: &'static str = "Terminal text is not available on Windows yet.";

    pub fn not_available(window_id: String) -> Self {
        Self {
            type_: "terminal_content".into(),
            window_id,
            content: Self::NOT_AVAILABLE.into(),
            has_autosuggest: false,
        }
    }
}

/// `StateChangeMessage`. Not sent in phase 1 (spec 3.2).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StateChange {
    #[serde(rename = "type")]
    pub type_: String,
    #[serde(rename = "windowId")]
    pub window_id: String,
    pub state: String,
}

/// `PreferenceRestoreMessage`. `preferences` is the phone's own snapshot,
/// handed back byte-for-byte; `{}` is the "no backup" reply.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PreferenceRestore {
    #[serde(rename = "type")]
    pub type_: String,
    #[serde(rename = "deviceID", default, skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
    pub preferences: Value,
}

impl PreferenceRestore {
    pub fn new(device_id: Option<String>, preferences: Value) -> Self {
        Self { type_: "preferences_restore".into(), device_id, preferences }
    }

    pub fn no_backup(device_id: Option<String>) -> Self {
        Self::new(device_id, Value::Object(serde_json::Map::new()))
    }
}

// ---------------------------------------------------------------------------
// Phone -> host
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct AuthMessage {
    pub pin: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct HeartbeatAck {
    pub seq: i64,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct SelectWindow {
    #[serde(rename = "windowId")]
    pub window_id: String,
}

/// `RequestContentMessage`.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct RequestContent {
    #[serde(rename = "windowId")]
    pub window_id: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct SendText {
    #[serde(rename = "windowId")]
    pub window_id: String,
    pub text: String,
    #[serde(rename = "pressReturn")]
    pub press_return: bool,
    #[serde(rename = "messageId", default, skip_serializing_if = "Option::is_none")]
    pub message_id: Option<WireUuid>,
    /// Ignored on Windows: input always lands in the foreground window, so
    /// the target is always raised (spec 3.3).
    #[serde(rename = "raiseWindow", default, skip_serializing_if = "Option::is_none")]
    pub raise_window: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct QuickAction {
    #[serde(rename = "windowId")]
    pub window_id: String,
    pub action: String,
    #[serde(rename = "messageId", default, skip_serializing_if = "Option::is_none")]
    pub message_id: Option<WireUuid>,
    /// Ignored in phase 1: there is no content reading to re-validate against.
    #[serde(rename = "promptFingerprint", default, skip_serializing_if = "Option::is_none")]
    pub prompt_fingerprint: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct ArrangeWindows {
    pub layout: ArrangeLayout,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct MinimizeWindow {
    #[serde(rename = "windowId")]
    pub window_id: String,
    #[serde(rename = "messageId", default, skip_serializing_if = "Option::is_none")]
    pub message_id: Option<WireUuid>,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct CloseWindow {
    #[serde(rename = "windowId")]
    pub window_id: String,
    #[serde(rename = "messageId", default, skip_serializing_if = "Option::is_none")]
    pub message_id: Option<WireUuid>,
}

/// `SetPinMessage` (`Shared/MessageProtocol.swift`): the phone asks; the host
/// owns the pin set and answers with a fresh `layout_update`.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct SetPin {
    #[serde(rename = "windowId")]
    pub window_id: String,
    pub pinned: bool,
}

/// `SetColorMessage` (`Shared/WindowColor.swift`): `#RRGGBB`, or absent /
/// null to clear the user's choice.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct SetColor {
    #[serde(rename = "windowId")]
    pub window_id: String,
    #[serde(default)]
    pub color: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct PhoneLog {
    pub lines: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct PreferenceSnapshot {
    #[serde(rename = "deviceID")]
    pub device_id: String,
    /// Stored as-is (spec 3.3). Must be a JSON object, as `PreferencesSnapshot`
    /// is a struct on the Mac.
    pub preferences: serde_json::Map<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct PreferenceRequest {
    #[serde(rename = "deviceID")]
    pub device_id: String,
}

/// A decoded phone message the host acts on in phase 1.
#[derive(Debug, Clone, PartialEq)]
pub enum Incoming {
    Auth(AuthMessage),
    HeartbeatAck(HeartbeatAck),
    SelectWindow(SelectWindow),
    SendText(SendText),
    QuickAction(QuickAction),
    ArrangeWindows(ArrangeWindows),
    MinimizeWindow(MinimizeWindow),
    CloseWindow(CloseWindow),
    PhoneLog(PhoneLog),
    PreferencesSnapshot(PreferenceSnapshot),
    PreferencesRequest(PreferenceRequest),
    RequestContent(RequestContent),
    SetPin(SetPin),
    SetColor(SetColor),
}

/// Why a frame produced no `Incoming`. None of these closes the socket
/// (spec 3): the caller logs and carries on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    /// Not JSON, or JSON without a string `type`.
    BadJson,
    /// A type phase 1 does not handle (logged at debug level, ignored).
    Unknown(String),
    /// A known type whose fields do not match the Swift struct. The message is
    /// the serde error, never the payload (it may carry text or a PIN).
    BadPayload { type_: String, error: String },
}

#[derive(Deserialize)]
struct Envelope {
    #[serde(rename = "type")]
    type_: String,
}

/// The message types phase 1 decodes (spec 3.3). Everything else is ignored.
pub const HANDLED_TYPES: &[&str] = &[
    "auth",
    "heartbeat_ack",
    "select_window",
    "send_text",
    "quick_action",
    "arrange_windows",
    "minimize_window",
    "close_window",
    "phone_log",
    "preferences_snapshot",
    "preferences_request",
    "request_content",
    "set_pin",
    "set_color",
];

/// `MessageCoder.messageType(from:)`.
pub fn message_type(text: &str) -> Option<String> {
    serde_json::from_str::<Envelope>(text).ok().map(|e| e.type_)
}

/// A serde error without the values it quotes: "invalid type: integer
/// `12345678`" would put an auth PIN (or dictated text) into websocket.log.
/// Field names are ours, so "missing field `x`" is kept.
fn scrub(e: &serde_json::Error) -> String {
    let msg = e.to_string();
    if msg.starts_with("missing field") {
        return msg;
    }
    let kind = match e.classify() {
        serde_json::error::Category::Io => "io",
        serde_json::error::Category::Syntax => "syntax",
        serde_json::error::Category::Data => "wrong type or value",
        serde_json::error::Category::Eof => "truncated",
    };
    format!("{kind} at line {} column {}", e.line(), e.column())
}

fn payload<T: serde::de::DeserializeOwned>(type_: &str, text: &str) -> Result<T, DecodeError> {
    serde_json::from_str(text).map_err(|e| DecodeError::BadPayload { type_: type_.to_string(), error: scrub(&e) })
}

/// Decode one text frame from the phone.
pub fn decode_incoming(text: &str) -> Result<Incoming, DecodeError> {
    let type_ = message_type(text).ok_or(DecodeError::BadJson)?;
    let t = type_.as_str();
    Ok(match t {
        "auth" => Incoming::Auth(payload(t, text)?),
        "heartbeat_ack" => Incoming::HeartbeatAck(payload(t, text)?),
        "select_window" => Incoming::SelectWindow(payload(t, text)?),
        "send_text" => Incoming::SendText(payload(t, text)?),
        "quick_action" => Incoming::QuickAction(payload(t, text)?),
        "arrange_windows" => Incoming::ArrangeWindows(payload(t, text)?),
        "minimize_window" => Incoming::MinimizeWindow(payload(t, text)?),
        "close_window" => Incoming::CloseWindow(payload(t, text)?),
        "phone_log" => Incoming::PhoneLog(payload(t, text)?),
        "preferences_snapshot" => Incoming::PreferencesSnapshot(payload(t, text)?),
        "preferences_request" => Incoming::PreferencesRequest(payload(t, text)?),
        "request_content" => Incoming::RequestContent(payload(t, text)?),
        "set_pin" => Incoming::SetPin(payload(t, text)?),
        "set_color" => Incoming::SetColor(payload(t, text)?),
        _ => return Err(DecodeError::Unknown(type_)),
    })
}

/// `MessageCoder.encode`. The Mac sorts keys; JSON object order is not
/// significant to any peer, so serde's field order is kept.
pub fn encode<T: Serialize>(msg: &T) -> Option<String> {
    serde_json::to_string(msg).ok()
}

#[cfg(test)]
mod tests {
    //! Ports of the phase-1 cases in `Shared/Tests/MessageProtocolTests.swift`
    //! and the wire-compat cases in `Shared/Tests/DisplayGeometryTests.swift`,
    //! plus the Windows-only "unknown / bad JSON ignored" cases.
    #![allow(non_snake_case)] // test names match the Swift ones they port
    use super::*;
    use serde_json::json;

    fn keys(v: &Value) -> Vec<String> {
        let mut k: Vec<String> = v.as_object().unwrap().keys().cloned().collect();
        k.sort();
        k
    }

    fn window(id: &str) -> WindowState {
        WindowState {
            id: id.into(),
            name: "PowerShell".into(),
            app: "Windows Terminal".into(),
            folder: None,
            enabled: true,
            frame: WindowFrame { x: 0.0, y: 0.0, width: 0.5, height: 1.0 },
            state: "neutral".into(),
            color: "#F5A623".into(),
            is_thinking: false,
            claude_mode: None,
            cli_kind: Some(CliKind::Shell),
            target_kind: None,
            display_id: Some("d1".into()),
            space_id: None,
            is_pinned: false,
            is_minimized: false,
            project: None,
        }
    }

    // --- auth / identity ---

    #[test]
    fn test_authMessage_decodes() {
        let m = decode_incoming(r#"{"type":"auth","pin":"12345678"}"#).unwrap();
        assert_eq!(m, Incoming::Auth(AuthMessage { pin: "12345678".into() }));
    }

    #[test]
    fn test_authResult_success_omitsError() {
        let v = serde_json::to_value(AuthResult::success()).unwrap();
        assert_eq!(v, json!({"type":"auth_result","success":true}));
    }

    #[test]
    fn test_authResult_failure_carriesError() {
        let v = serde_json::to_value(AuthResult::failure("Incorrect PIN")).unwrap();
        assert_eq!(v, json!({"type":"auth_result","success":false,"error":"Incorrect PIN"}));
    }

    #[test]
    fn auth_required_signal_is_the_string_the_phone_matches() {
        let v = serde_json::to_value(AuthResult::auth_required()).unwrap();
        assert_eq!(v["error"], "auth_required");
        assert_eq!(v["success"], false);
    }

    #[test]
    fn test_deviceIdentity_roundTrip_withLocalURLs() {
        let m = DeviceIdentity::windows(
            "FA4E3AC0-0000-4000-8000-000000000002".into(),
            "PC".into(),
            vec!["ws://192.168.1.20:8765".into()],
        );
        let v = serde_json::to_value(&m).unwrap();
        assert_eq!(keys(&v), ["deviceID", "deviceKind", "displayName", "localURLs", "type"]);
        assert_eq!(v["deviceKind"], "windows");
        let back: DeviceIdentity = serde_json::from_value(v).unwrap();
        assert_eq!(back, m);
    }

    #[test]
    fn test_deviceIdentity_decodesWithoutLocalURLs() {
        let m: DeviceIdentity =
            serde_json::from_str(r#"{"type":"device_identity","deviceID":"x","deviceKind":"mac","displayName":"M"}"#)
                .unwrap();
        assert_eq!(m.local_urls, None);
    }

    // --- layout ---

    #[test]
    fn test_windowState_encodesSwiftKeySet_andOmitsNilOptionals() {
        let v = serde_json::to_value(window("w-1")).unwrap();
        assert_eq!(
            keys(&v),
            [
                "app",
                "cliKind",
                "color",
                "displayID",
                "enabled",
                "frame",
                "id",
                "isMinimized",
                "isPinned",
                "isThinking",
                "name",
                "state"
            ]
        );
        assert!(v.get("folder").is_none(), "nil is omitted, as Swift's synthesized encoder does");
    }

    #[test]
    fn test_windowState_decodesWithoutOptionalFields() {
        let w: WindowState = serde_json::from_value(json!({
            "id":"a","name":"n","app":"x","enabled":true,
            "frame":{"x":0,"y":0,"width":1,"height":1},"state":"neutral","color":"#FFFFFF"
        }))
        .unwrap();
        assert!(!w.is_thinking && !w.is_pinned && !w.is_minimized);
        assert_eq!(w.cli_kind, None);
        assert_eq!(w.display_id, None, "nil means 'the primary display' to the client");
        assert_eq!(w.space_id, None);
    }

    #[test]
    fn test_windowState_wrongTypedOptionalReadsAsNil() {
        // `try? c.decode(...)`: a bad optional does not sink the window.
        let w: WindowState = serde_json::from_value(json!({
            "id":"a","name":"n","app":"x","enabled":true,
            "frame":{"x":0,"y":0,"width":1,"height":1},"state":"neutral","color":"#FFFFFF",
            "folder": 3, "cliKind": "bogus", "isPinned": "yes", "displayID": null
        }))
        .unwrap();
        assert_eq!(w.folder, None);
        assert_eq!(w.cli_kind, None);
        assert!(!w.is_pinned);
    }

    #[test]
    fn test_windowState_missingRequiredFieldFails() {
        let r: Result<WindowState, _> = serde_json::from_value(json!({
            "id":"a","name":"n","app":"x",
            "frame":{"x":0,"y":0,"width":1,"height":1},"state":"neutral","color":"#FFFFFF"
        }));
        assert!(r.is_err(), "`enabled` is non-optional on the Mac");
    }

    #[test]
    fn test_layoutUpdate_roundTripsDisplays() {
        let displays = vec![
            DisplayState {
                id: "d1".into(),
                name: "FakeWindows Display".into(),
                is_primary: true,
                aspect: 16.0 / 9.0,
                span_frame: WindowFrame { x: 0.0, y: 0.0, width: 0.5, height: 1.0 },
            },
            DisplayState {
                id: "d2".into(),
                name: "Second".into(),
                is_primary: false,
                aspect: 16.0 / 9.0,
                span_frame: WindowFrame { x: 0.5, y: 0.0, width: 0.5, height: 1.0 },
            },
        ];
        let u = LayoutUpdate::new(
            "FakeWindows Display".into(),
            Some(16.0 / 9.0),
            vec![window("w-1")],
            Some(displays.clone()),
            Some(32.0 / 9.0),
        );
        let s = encode(&u).unwrap();
        let back: LayoutUpdate = serde_json::from_str(&s).unwrap();
        assert_eq!(back.displays, Some(displays));
        assert_eq!(back.span_aspect, Some(32.0 / 9.0));
        assert!(!s.contains("\"spaces\""), "spaces are phase 2 and omitted");
    }

    #[test]
    fn test_layoutUpdate_withoutDisplaysStillDecodes() {
        let u: LayoutUpdate = serde_json::from_str(r#"{"type":"layout_update","monitor":"M","windows":[]}"#).unwrap();
        assert_eq!(u.displays, None);
        assert_eq!(u.span_aspect, None);
        assert_eq!(u.monitor, "M");
    }

    // --- host -> phone singles ---

    #[test]
    fn test_frontmostChanged_nilWindowIdIsOmitted() {
        let v = serde_json::to_value(FrontmostChanged::new(None)).unwrap();
        assert_eq!(v, json!({"type":"frontmost_changed"}));
        let v = serde_json::to_value(FrontmostChanged::new(Some("w-1".into()))).unwrap();
        assert_eq!(v, json!({"type":"frontmost_changed","windowId":"w-1"}));
        let back: FrontmostChanged = serde_json::from_str(r#"{"type":"frontmost_changed","windowId":null}"#).unwrap();
        assert_eq!(back.window_id, None);
    }

    #[test]
    fn test_heartbeat_encodesSeqAndTs() {
        let v = serde_json::to_value(Heartbeat::new(7, 1_800_000_000.5)).unwrap();
        assert_eq!(v, json!({"type":"heartbeat","seq":7,"ts":1_800_000_000.5}));
    }

    #[test]
    fn test_heartbeatAck_decodes() {
        let m = decode_incoming(r#"{"type":"heartbeat_ack","seq":42}"#).unwrap();
        assert_eq!(m, Incoming::HeartbeatAck(HeartbeatAck { seq: 42 }));
    }

    #[test]
    fn test_sendTextAck_shape() {
        let id = WireUuid::parse("6ba7b810-9dad-11d1-80b4-00c04fd430c8").unwrap();
        let v = serde_json::to_value(SendTextAck::new(id, 12, 40)).unwrap();
        assert_eq!(
            v,
            json!({"type":"send_text_ack","messageId":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8",
                   "injectMs":12,"totalMs":40,"path":"sendText"})
        );
    }

    #[test]
    fn test_errorMessage_withAndWithoutMessageId() {
        let v = serde_json::to_value(ErrorMessage::new("Window no longer exists", None)).unwrap();
        assert_eq!(v, json!({"type":"error","reason":"Window no longer exists"}));
        let id = WireUuid::parse("6ba7b810-9dad-11d1-80b4-00c04fd430c8").unwrap();
        let v = serde_json::to_value(ErrorMessage::new("x", Some(id))).unwrap();
        assert_eq!(v["messageId"], "6BA7B810-9DAD-11D1-80B4-00C04FD430C8");
    }

    #[test]
    fn test_preferenceRestore_noBackupIsEmptyObject() {
        let v = serde_json::to_value(PreferenceRestore::no_backup(Some("dev".into()))).unwrap();
        assert_eq!(v, json!({"type":"preferences_restore","deviceID":"dev","preferences":{}}));
    }

    // --- phone -> host ---

    #[test]
    fn test_sendText_minimal() {
        let m = decode_incoming(r#"{"type":"send_text","windowId":"w-1","text":"hi","pressReturn":true}"#).unwrap();
        let Incoming::SendText(s) = m else { panic!("wrong variant") };
        assert_eq!(s.message_id, None);
        assert_eq!(s.raise_window, None);
        assert!(s.press_return);
    }

    #[test]
    fn test_sendText_full() {
        let m = decode_incoming(
            r#"{"type":"send_text","windowId":"w-1","text":"hi","pressReturn":false,
                "messageId":"6ba7b810-9dad-11d1-80b4-00c04fd430c8","raiseWindow":false}"#,
        )
        .unwrap();
        let Incoming::SendText(s) = m else { panic!("wrong variant") };
        assert!(s.message_id.is_some());
        assert_eq!(s.raise_window, Some(false));
    }

    #[test]
    fn test_sendText_nullMessageIdIsNil() {
        let m =
            decode_incoming(r#"{"type":"send_text","windowId":"w","text":"t","pressReturn":true,"messageId":null}"#)
                .unwrap();
        let Incoming::SendText(s) = m else { panic!("wrong variant") };
        assert_eq!(s.message_id, None);
    }

    #[test]
    fn test_sendText_invalidMessageIdFailsLikeSwift() {
        let r =
            decode_incoming(r#"{"type":"send_text","windowId":"w","text":"t","pressReturn":true,"messageId":"nope"}"#);
        assert!(matches!(r, Err(DecodeError::BadPayload { .. })));
    }

    #[test]
    fn test_sendText_missingPressReturnFails() {
        let r = decode_incoming(r#"{"type":"send_text","windowId":"w","text":"t"}"#);
        assert!(matches!(r, Err(DecodeError::BadPayload { ref type_, .. }) if type_ == "send_text"));
    }

    #[test]
    fn test_quickAction_decodesFingerprint() {
        let m =
            decode_incoming(r#"{"type":"quick_action","windowId":"w","action":"press_y","promptFingerprint":"abc"}"#)
                .unwrap();
        let Incoming::QuickAction(q) = m else { panic!("wrong variant") };
        assert_eq!(q.prompt_fingerprint.as_deref(), Some("abc"));
        assert_eq!(q.message_id, None);
    }

    #[test]
    fn test_arrangeWindows_wireEnumStillRejectsGrid() {
        assert!(decode_incoming(r#"{"type":"arrange_windows","layout":"grid"}"#).is_err());
        let m = decode_incoming(r#"{"type":"arrange_windows","layout":"horizontal"}"#).unwrap();
        assert_eq!(m, Incoming::ArrangeWindows(ArrangeWindows { layout: ArrangeLayout::Horizontal }));
    }

    #[test]
    fn test_minimizeAndClose_decode() {
        let m = decode_incoming(r#"{"type":"minimize_window","windowId":"w"}"#).unwrap();
        assert!(matches!(m, Incoming::MinimizeWindow(_)));
        let m = decode_incoming(
            r#"{"type":"close_window","windowId":"w","messageId":"6ba7b810-9dad-11d1-80b4-00c04fd430c8"}"#,
        )
        .unwrap();
        let Incoming::CloseWindow(c) = m else { panic!("wrong variant") };
        assert!(c.message_id.is_some());
    }

    #[test]
    fn test_phoneLog_decodes() {
        let m = decode_incoming(r#"{"type":"phone_log","lines":["a","b"]}"#).unwrap();
        assert_eq!(m, Incoming::PhoneLog(PhoneLog { lines: vec!["a".into(), "b".into()] }));
    }

    #[test]
    fn test_preferencesSnapshot_keepsUnknownKeys() {
        let m = decode_incoming(
            r#"{"type":"preferences_snapshot","deviceID":"d","preferences":{"pushSound":true,"futureKey":[1,2]}}"#,
        )
        .unwrap();
        let Incoming::PreferencesSnapshot(p) = m else { panic!("wrong variant") };
        assert_eq!(p.preferences["futureKey"], json!([1, 2]));
    }

    #[test]
    fn test_preferencesSnapshot_nonObjectFails() {
        assert!(decode_incoming(r#"{"type":"preferences_snapshot","deviceID":"d","preferences":3}"#).is_err());
    }

    #[test]
    fn test_preferencesRequest_decodes() {
        let m = decode_incoming(r#"{"type":"preferences_request","deviceID":"d"}"#).unwrap();
        assert_eq!(m, Incoming::PreferencesRequest(PreferenceRequest { device_id: "d".into() }));
    }

    // --- Windows-only: never a disconnect ---

    #[test]
    fn unknown_type_is_reported_not_decoded() {
        for t in ["image_upload", "spawn_window", "set_qa_pair", "duplicate_window", "zzz"] {
            let r = decode_incoming(&format!(r#"{{"type":"{t}"}}"#));
            assert_eq!(r, Err(DecodeError::Unknown(t.to_string())));
        }
    }

    #[test]
    fn request_content_decodes_and_terminal_content_has_the_swift_keys() {
        let m = decode_incoming(r#"{"type":"request_content","windowId":"w-1"}"#).unwrap();
        assert_eq!(m, Incoming::RequestContent(RequestContent { window_id: "w-1".into() }));
        let v = serde_json::to_value(TerminalContent::not_available("w-1".into())).unwrap();
        assert_eq!(
            v,
            json!({"type":"terminal_content","windowId":"w-1",
                   "content":"Terminal text is not available on Windows yet.","hasAutosuggest":false})
        );
    }

    #[test]
    fn bad_json_is_reported_not_decoded() {
        for bad in ["", "{", "[]", "null", r#"{"type":3}"#, r#"{"notype":"auth"}"#, "\u{0}"] {
            assert_eq!(decode_incoming(bad), Err(DecodeError::BadJson), "{bad:?}");
        }
    }

    #[test]
    fn bad_payload_error_never_echoes_the_payload() {
        let r = decode_incoming(r#"{"type":"auth","pin":12345678}"#);
        let Err(DecodeError::BadPayload { error, .. }) = r else { panic!("expected BadPayload") };
        assert!(!error.contains("12345678"), "{error}");
    }

    #[test]
    fn set_pin_and_set_color_decode_the_swift_field_names() {
        assert_eq!(
            decode_incoming(r#"{"type":"set_pin","windowId":"w1","pinned":true}"#),
            Ok(Incoming::SetPin(SetPin { window_id: "w1".into(), pinned: true }))
        );
        assert_eq!(
            decode_incoming(r##"{"type":"set_color","windowId":"w1","color":"#4A90D9"}"##),
            Ok(Incoming::SetColor(SetColor { window_id: "w1".into(), color: Some("#4A90D9".into()) }))
        );
        // Swift encodes a nil `color` by leaving the key out; null is accepted too.
        for clear in [r#"{"type":"set_color","windowId":"w1"}"#, r#"{"type":"set_color","windowId":"w1","color":null}"#]
        {
            assert_eq!(
                decode_incoming(clear),
                Ok(Incoming::SetColor(SetColor { window_id: "w1".into(), color: None }))
            );
        }
        assert!(matches!(
            decode_incoming(r#"{"type":"set_pin","windowId":"w1"}"#),
            Err(DecodeError::BadPayload { .. })
        ));
    }

    #[test]
    fn every_handled_type_is_decodable() {
        for t in HANDLED_TYPES {
            // A bare envelope of a handled type is a BadPayload (missing
            // fields), never Unknown: the dispatcher knows it.
            let r = decode_incoming(&format!(r#"{{"type":"{t}"}}"#));
            assert!(!matches!(r, Err(DecodeError::Unknown(_))), "{t}");
        }
    }

    #[test]
    fn test_messageType_extraction() {
        assert_eq!(message_type(r#"{"type":"auth","pin":"1"}"#).as_deref(), Some("auth"));
        assert_eq!(message_type("garbage"), None);
    }

    #[test]
    fn scrubbed_errors_keep_field_names_and_position_only() {
        let Err(DecodeError::BadPayload { error, .. }) = decode_incoming(r#"{"type":"auth"}"#) else { panic!() };
        assert!(error.starts_with("missing field `pin`"), "{error}");
        let Err(DecodeError::BadPayload { error, .. }) = decode_incoming(r#"{"type":"auth","pin":true}"#) else {
            panic!()
        };
        assert_eq!(error, "wrong type or value at line 1 column 25");
    }
}
