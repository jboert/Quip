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
    pub windows: Vec<WindowState>,
}

impl LayoutUpdate {
    pub fn new(monitor: String, windows: Vec<WindowState>) -> Self {
        Self {
            type_: "layout_update".into(),
            monitor,
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
    pub enabled: bool,
    pub frame: WindowFrame,
    pub state: String,
    pub color: String,
    #[serde(default, rename = "isThinking")]
    pub is_thinking: bool,
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

#[derive(Debug, Clone, Serialize)]
pub struct TerminalContentMessage {
    #[serde(rename = "type")]
    pub type_: String,
    #[serde(rename = "windowId")]
    pub window_id: String,
    pub content: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub screenshot: Option<String>,
}

impl TerminalContentMessage {
    pub fn new(window_id: String, content: String) -> Self {
        Self {
            type_: "terminal_content".into(),
            window_id,
            content,
            screenshot: None,
        }
    }

    pub fn with_screenshot(window_id: String, content: String, screenshot: String) -> Self {
        Self {
            type_: "terminal_content".into(),
            window_id,
            content,
            screenshot: Some(screenshot),
        }
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
