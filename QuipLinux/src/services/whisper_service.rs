use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, RwLock};

use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use uuid::Uuid;

use crate::protocol::messages::{
    encode_message, AudioChunkMessage, TranscriptResultMessage, WhisperState, WhisperStatusMessage,
};

/// Default GGML model — small, English-only, ~150 MB. Trade-off: slightly
/// less accurate than `base.en` but compiles + runs on a Pi-class CPU. Users
/// who want better accuracy can drop a different file at the same path.
const DEFAULT_MODEL_FILENAME: &str = "ggml-base.en.bin";
const MODEL_DOWNLOAD_URL: &str =
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin";

/// Linux equivalent of QuipMac/Services/WhisperDictationService.swift.
///
/// Receives `audio_chunk` messages keyed by session UUID, accumulates the
/// raw int16 PCM into a per-session buffer, and on `is_final == true` runs
/// whisper.cpp via the `whisper-rs` crate. The transcript is sent back as a
/// `transcript_result` over the same broadcast channel as everything else.
///
/// Model lifecycle (`preparing` → `downloading` → `ready` | `failed`) is
/// broadcast as `whisper_status` so the iPhone can tell the user whether the
/// remote-recognizer path is viable at PTT-start.
pub struct WhisperService {
    /// Audio buffers, keyed by session UUID. int16 mono 16 kHz PCM samples.
    sessions: Mutex<HashMap<Uuid, Vec<i16>>>,
    /// The loaded whisper context (None until the model is on disk and parsed).
    /// Wrapped in Mutex<Option<...>> because building one is fallible and we
    /// only attempt it lazily on first chunk.
    ctx: Arc<Mutex<Option<WhisperCtxWrapper>>>,
    /// Last-known model lifecycle state, kept in shared memory so
    /// `current_state()` can serve a snapshot to new clients on connect.
    state: Arc<RwLock<WhisperState>>,
    /// Path the model file lives at.
    model_path: PathBuf,
    /// Broadcast channel — every transcript / status message goes through
    /// here so all connected clients see updates.
    broadcast: async_channel::Sender<String>,
}

/// Newtype wrapper so we can keep `WhisperContext` behind a Mutex without
/// the rest of the file depending on the crate's exact type names.
#[cfg(feature = "whisper")]
struct WhisperCtxWrapper(whisper_rs::WhisperContext);

#[cfg(not(feature = "whisper"))]
struct WhisperCtxWrapper;

impl WhisperService {
    /// Default production initializer — model lives in `~/.cache/quip/models`.
    pub fn new(broadcast: async_channel::Sender<String>) -> Arc<Self> {
        let model_path = directories::ProjectDirs::from("dev", "quip", "quip")
            .map(|p| p.cache_dir().join("models").join(DEFAULT_MODEL_FILENAME))
            .unwrap_or_else(|| PathBuf::from("/tmp/quip-whisper-model.bin"));
        Arc::new(Self {
            sessions: Mutex::new(HashMap::new()),
            ctx: Arc::new(Mutex::new(None)),
            state: Arc::new(RwLock::new(WhisperState::Preparing)),
            model_path,
            broadcast,
        })
    }

    pub fn current_state(&self) -> WhisperState {
        self.state.read().expect("whisper state poisoned").clone()
    }

    /// Spawn a background task to ensure the model is on disk and loaded.
    /// Idempotent — returns immediately on second call.
    pub fn ensure_model_async(self: &Arc<Self>) {
        let me = Arc::clone(self);
        std::thread::spawn(move || {
            me.ensure_model_blocking();
        });
    }

    fn ensure_model_blocking(self: &Arc<Self>) {
        if self.ctx.lock().unwrap().is_some() {
            return;
        }
        self.set_state(WhisperState::Preparing);

        if !self.model_path.exists() {
            if let Err(e) = self.download_model_blocking() {
                self.set_state(WhisperState::Failed { message: e });
                return;
            }
        }

        match Self::load_model(&self.model_path) {
            Ok(ctx) => {
                *self.ctx.lock().unwrap() = Some(ctx);
                self.set_state(WhisperState::Ready);
            }
            Err(e) => {
                self.set_state(WhisperState::Failed { message: e });
            }
        }
    }

    fn download_model_blocking(self: &Arc<Self>) -> Result<(), String> {
        if let Some(parent) = self.model_path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        self.set_state(WhisperState::Downloading { progress: 0.0 });

        let mut resp = reqwest::blocking::get(MODEL_DOWNLOAD_URL)
            .map_err(|e| format!("model download request failed: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("model download HTTP {}", resp.status()));
        }
        let total = resp.content_length().unwrap_or(0);

        let tmp_path = self.model_path.with_extension("partial");
        let mut tmp = std::fs::File::create(&tmp_path).map_err(|e| e.to_string())?;

        let mut buf = vec![0u8; 64 * 1024];
        let mut written: u64 = 0;
        let mut last_pct_announced: f64 = -1.0;
        loop {
            let n = std::io::Read::read(&mut resp, &mut buf)
                .map_err(|e| format!("model download read failed: {e}"))?;
            if n == 0 {
                break;
            }
            std::io::Write::write_all(&mut tmp, &buf[..n])
                .map_err(|e| format!("model download write failed: {e}"))?;
            written += n as u64;
            if total > 0 {
                let pct = (written as f64 / total as f64).min(1.0);
                // Announce roughly every 5% to avoid hammering the broadcast.
                if (pct - last_pct_announced) >= 0.05 || pct == 1.0 {
                    last_pct_announced = pct;
                    self.set_state(WhisperState::Downloading { progress: pct });
                }
            }
        }
        drop(tmp);
        std::fs::rename(&tmp_path, &self.model_path).map_err(|e| e.to_string())?;
        Ok(())
    }

    #[cfg(feature = "whisper")]
    fn load_model(path: &std::path::Path) -> Result<WhisperCtxWrapper, String> {
        use whisper_rs::{WhisperContext, WhisperContextParameters};
        let path_str = path.to_string_lossy().to_string();
        WhisperContext::new_with_params(&path_str, WhisperContextParameters::default())
            .map(WhisperCtxWrapper)
            .map_err(|e| format!("whisper model load failed: {e}"))
    }

    #[cfg(not(feature = "whisper"))]
    fn load_model(_path: &std::path::Path) -> Result<WhisperCtxWrapper, String> {
        Err("whisper-rs feature disabled at compile time".into())
    }

    /// Append an audio chunk to its session's buffer. On `is_final`, kick off
    /// transcription on a background thread.
    pub fn handle_chunk(self: &Arc<Self>, msg: AudioChunkMessage) {
        let bytes = match BASE64.decode(msg.pcm_base64.as_bytes()) {
            Ok(b) => b,
            Err(e) => {
                self.send_error(msg.session_id, format!("invalid base64 PCM: {e}"));
                return;
            }
        };

        // i16 little-endian → Vec<i16>
        let samples: Vec<i16> = bytes
            .chunks_exact(2)
            .map(|c| i16::from_le_bytes([c[0], c[1]]))
            .collect();

        {
            let mut sessions = self.sessions.lock().unwrap();
            sessions.entry(msg.session_id).or_default().extend(samples);
        }

        if msg.is_final {
            let me = Arc::clone(self);
            let session_id = msg.session_id;
            std::thread::spawn(move || me.finalize_session(session_id));
        }
    }

    fn finalize_session(self: &Arc<Self>, session_id: Uuid) {
        let pcm = match self.sessions.lock().unwrap().remove(&session_id) {
            Some(p) if !p.is_empty() => p,
            _ => {
                self.send_error(session_id, "no audio buffered for this session".into());
                return;
            }
        };

        // Make sure the model is loaded (will block here if first call).
        self.ensure_model_blocking();
        let mut ctx_guard = self.ctx.lock().unwrap();
        let ctx = match ctx_guard.as_mut() {
            Some(c) => c,
            None => {
                self.send_error(session_id, "whisper model not loaded".into());
                return;
            }
        };

        let audio_f32: Vec<f32> = pcm.iter().map(|&s| s as f32 / 32768.0).collect();

        match Self::transcribe(ctx, &audio_f32) {
            Ok(text) => {
                let msg = TranscriptResultMessage::ok(session_id, text.trim().into());
                if let Some(json) = encode_message(&msg) {
                    let _ = self.broadcast.try_send(json);
                }
            }
            Err(e) => self.send_error(session_id, e),
        }
    }

    #[cfg(feature = "whisper")]
    fn transcribe(ctx: &mut WhisperCtxWrapper, audio: &[f32]) -> Result<String, String> {
        use whisper_rs::{FullParams, SamplingStrategy};
        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_print_progress(false);
        params.set_print_special(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_language(Some("en"));

        let mut state = ctx
            .0
            .create_state()
            .map_err(|e| format!("whisper state init failed: {e}"))?;
        state
            .full(params, audio)
            .map_err(|e| format!("whisper transcribe failed: {e}"))?;

        let n = state
            .full_n_segments()
            .map_err(|e| format!("segment count failed: {e}"))?;
        let mut text = String::new();
        for i in 0..n {
            let seg = state
                .full_get_segment_text(i)
                .map_err(|e| format!("segment text failed: {e}"))?;
            text.push_str(&seg);
        }
        Ok(text)
    }

    #[cfg(not(feature = "whisper"))]
    fn transcribe(_ctx: &mut WhisperCtxWrapper, _audio: &[f32]) -> Result<String, String> {
        Err("whisper-rs feature disabled at compile time".into())
    }

    fn send_error(&self, session_id: Uuid, message: String) {
        let msg = TranscriptResultMessage::err(session_id, message);
        if let Some(json) = encode_message(&msg) {
            let _ = self.broadcast.try_send(json);
        }
    }

    fn set_state(&self, new_state: WhisperState) {
        {
            let mut s = self.state.write().expect("whisper state poisoned");
            *s = new_state.clone();
        }
        let msg = WhisperStatusMessage::new(new_state);
        if let Some(json) = encode_message(&msg) {
            let _ = self.broadcast.try_send(json);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dummy_service() -> Arc<WhisperService> {
        let (tx, _rx) = async_channel::unbounded();
        WhisperService::new(tx)
    }

    #[test]
    fn current_state_starts_preparing() {
        let s = dummy_service();
        assert_eq!(s.current_state(), WhisperState::Preparing);
    }

    #[test]
    fn handle_chunk_decodes_and_buffers_pcm() {
        let s = dummy_service();
        // Two int16 samples little-endian: 0x0001, 0x0002
        let pcm = vec![1i16, 2i16];
        let bytes: Vec<u8> = pcm.iter().flat_map(|s| s.to_le_bytes()).collect();
        let b64 = BASE64.encode(&bytes);
        let id = Uuid::new_v4();
        s.handle_chunk(AudioChunkMessage {
            type_: "audio_chunk".into(),
            session_id: id,
            seq: 0,
            pcm_base64: b64,
            is_final: false,
        });
        let buf = s.sessions.lock().unwrap();
        assert_eq!(buf.get(&id).cloned().unwrap_or_default(), vec![1i16, 2i16]);
    }

    #[test]
    fn invalid_base64_emits_error_transcript() {
        let (tx, rx) = async_channel::unbounded();
        let s = WhisperService::new(tx);
        let id = Uuid::new_v4();
        s.handle_chunk(AudioChunkMessage {
            type_: "audio_chunk".into(),
            session_id: id,
            seq: 0,
            pcm_base64: "!!!nope!!!".into(),
            is_final: false,
        });
        let json = rx.try_recv().expect("expected an error transcript_result");
        assert!(json.contains("transcript_result"));
        assert!(json.contains("invalid base64"));
    }
}
