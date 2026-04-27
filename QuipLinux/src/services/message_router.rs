use crate::protocol::messages::{
    message_type, ArrangeWindowsMessage, AudioChunkMessage, CloseWindowMessage,
    DuplicateWindowMessage, ImageUploadMessage, OpenMacSettingsPaneMessage,
    PreferenceRequestMessage, PreferenceSnapshotMessage, PushPreferencesMessage,
    QuickActionMessage, RegisterPushDeviceMessage, RequestContentMessage, SelectWindowMessage,
    SendTextMessage, SpawnWindowMessage, SttStateMessage,
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
    DuplicateWindow(String),
    CloseWindow(String),
    ImageUpload(ImageUploadMessage),
    AudioChunk(AudioChunkMessage),
    RegisterPushDevice(RegisterPushDeviceMessage),
    PushPreferences(PushPreferencesMessage),
    SpawnWindow(String),
    ArrangeWindows(String),
    OpenSettingsPane(OpenMacSettingsPaneMessage),
    PreferencesSnapshot(PreferenceSnapshotMessage),
    PreferencesRequest(PreferenceRequestMessage),
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
        "duplicate_window" => {
            let msg: DuplicateWindowMessage = serde_json::from_str(json).ok()?;
            Some(IncomingAction::DuplicateWindow(msg.source_window_id))
        }
        "close_window" => {
            let msg: CloseWindowMessage = serde_json::from_str(json).ok()?;
            Some(IncomingAction::CloseWindow(msg.window_id))
        }
        "image_upload" => {
            let msg: ImageUploadMessage = serde_json::from_str(json).ok()?;
            Some(IncomingAction::ImageUpload(msg))
        }
        "audio_chunk" => {
            let msg: AudioChunkMessage = serde_json::from_str(json).ok()?;
            Some(IncomingAction::AudioChunk(msg))
        }
        "register_push_device" => {
            let msg: RegisterPushDeviceMessage = serde_json::from_str(json).ok()?;
            Some(IncomingAction::RegisterPushDevice(msg))
        }
        "push_preferences" => {
            let msg: PushPreferencesMessage = serde_json::from_str(json).ok()?;
            Some(IncomingAction::PushPreferences(msg))
        }
        "spawn_window" => {
            let msg: SpawnWindowMessage = serde_json::from_str(json).ok()?;
            Some(IncomingAction::SpawnWindow(msg.directory))
        }
        "arrange_windows" => {
            let msg: ArrangeWindowsMessage = serde_json::from_str(json).ok()?;
            Some(IncomingAction::ArrangeWindows(msg.layout))
        }
        "open_mac_settings_pane" => {
            let msg: OpenMacSettingsPaneMessage = serde_json::from_str(json).ok()?;
            Some(IncomingAction::OpenSettingsPane(msg))
        }
        "preferences_snapshot" => {
            let msg: PreferenceSnapshotMessage = serde_json::from_str(json).ok()?;
            Some(IncomingAction::PreferencesSnapshot(msg))
        }
        "preferences_request" => {
            let msg: PreferenceRequestMessage = serde_json::from_str(json).ok()?;
            Some(IncomingAction::PreferencesRequest(msg))
        }
        other => {
            warn!("Unknown message type: {other}");
            None
        }
    }
}
