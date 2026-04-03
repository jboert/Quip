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
