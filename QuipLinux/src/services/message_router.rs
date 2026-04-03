use crate::protocol::messages::{
    message_type, QuickActionMessage, RequestContentMessage, SelectWindowMessage, SendTextMessage,
    SttStateMessage,
};
use tracing::warn;

/// Parsed incoming action from a WebSocket client.
#[derive(Debug, Clone)]
pub enum IncomingAction {
    SelectWindow(String),
    SendText {
        window_id: String,
        text: String,
        press_return: bool,
    },
    QuickAction {
        window_id: String,
        action: String,
    },
    SttStarted(String),
    SttEnded(String),
    RequestContent(String),
}

/// Parse a JSON message from a client into a typed action.
pub fn parse_incoming(json: &str) -> Option<IncomingAction> {
    let msg_type = message_type(json)?;

    match msg_type.as_str() {
        "select_window" => {
            let msg: SelectWindowMessage = serde_json::from_str(json).ok()?;
            Some(IncomingAction::SelectWindow(msg.window_id))
        }
        "send_text" => {
            let msg: SendTextMessage = serde_json::from_str(json).ok()?;
            Some(IncomingAction::SendText {
                window_id: msg.window_id,
                text: msg.text,
                press_return: msg.press_return,
            })
        }
        "quick_action" => {
            let msg: QuickActionMessage = serde_json::from_str(json).ok()?;
            Some(IncomingAction::QuickAction {
                window_id: msg.window_id,
                action: msg.action,
            })
        }
        "stt_started" => {
            let msg: SttStateMessage = serde_json::from_str(json).ok()?;
            Some(IncomingAction::SttStarted(msg.window_id))
        }
        "stt_ended" => {
            let msg: SttStateMessage = serde_json::from_str(json).ok()?;
            Some(IncomingAction::SttEnded(msg.window_id))
        }
        "request_content" => {
            let msg: RequestContentMessage = serde_json::from_str(json).ok()?;
            Some(IncomingAction::RequestContent(msg.window_id))
        }
        other => {
            warn!("Unknown message type: {other}");
            None
        }
    }
}
