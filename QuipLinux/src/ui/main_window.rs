use glib::clone;
use gtk4::prelude::*;
use gtk4::{self, Align, Orientation, PolicyType, ScrolledWindow};
use libadwaita as adw;
use libadwaita::prelude::*;
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::sync::atomic::Ordering;
use std::sync::Arc;

use crate::models::layout::{CustomLayoutTemplate, LayoutCalculator, LayoutMode};
use crate::models::settings::NetworkMode;
use crate::platform;
use crate::protocol::messages::{encode_message, TTSAudioMessage};
use crate::services::message_router;
use crate::services::tailscale::TailscaleService;
use crate::state::{self, SharedState};

use super::layout_preview::LayoutPreviewWidget;
use super::status_bar::StatusBar;
use super::window_list::WindowListWidget;

/// Commands sent from the GTK thread to the tokio runtime to reconfigure services
/// without needing an app restart.
#[derive(Debug, Clone)]
pub enum RuntimeCommand {
    /// User switched the network mode. Start/stop the tunnel and Tailscale
    /// detector to match, and reload require_auth on the WebSocket server.
    SetNetworkMode(NetworkMode),
    /// Manual "Re-detect" button in the Connection settings tab.
    RefreshTailscale,
    /// User changed the "require PIN for local" toggle. Reload require_auth on
    /// the WebSocket server from current settings.
    ReloadAuth,
}

/// Build the main GTK4 UI and start background services
pub fn build_ui(app: &adw::Application) {
    let shared_state = state::new_shared_state();
    let (window_backend, input_backend, _session) = platform::create_backends();

    // Wrap backends in Arc for sharing across threads
    let window_backend: Arc<dyn platform::traits::WindowBackend> = Arc::from(window_backend);
    let input_backend: Arc<dyn platform::traits::InputBackend> = Arc::from(input_backend);

    // Initial refresh
    {
        let mut state = shared_state.write().unwrap();
        state.refresh_displays(&*window_backend);
        state.refresh_windows(&*window_backend);
        state.refresh_subtitles();
    }

    // UI state
    let layout_mode = Rc::new(RefCell::new(LayoutMode::Columns));
    let custom_template = Rc::new(RefCell::new(CustomLayoutTemplate::LargeLeftSmallRight));

    // --- Build window ---
    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("Quip")
        .default_width(960)
        .default_height(640)
        .build();

    let main_box = gtk4::Box::new(Orientation::Horizontal, 0);

    // --- Sidebar ---
    let sidebar_widget = WindowListWidget::new(shared_state.clone(), input_backend.clone());
    let sidebar_frame = gtk4::Frame::new(None);
    sidebar_frame.set_child(Some(sidebar_widget.container()));
    sidebar_frame.set_width_request(260);

    // --- Detail pane ---
    let detail_box = gtk4::Box::new(Orientation::Vertical, 0);
    detail_box.set_hexpand(true);
    detail_box.set_vexpand(true);

    // Layout mode selector
    let mode_box = gtk4::Box::new(Orientation::Horizontal, 8);
    mode_box.set_margin_start(16);
    mode_box.set_margin_end(16);
    mode_box.set_margin_top(12);
    mode_box.set_margin_bottom(8);

    let mode_buttons = gtk4::Box::new(Orientation::Horizontal, 0);
    mode_buttons.add_css_class("linked");

    for mode in LayoutMode::ALL {
        let btn = gtk4::ToggleButton::with_label(mode.label());
        if *mode == LayoutMode::Columns {
            btn.set_active(true);
        }
        let lm = layout_mode.clone();
        let mode_copy = *mode;
        btn.connect_toggled(move |button| {
            if button.is_active() {
                *lm.borrow_mut() = mode_copy;
            }
        });
        mode_buttons.append(&btn);
    }

    mode_box.append(&mode_buttons);

    detail_box.append(&mode_box);
    detail_box.append(&gtk4::Separator::new(Orientation::Horizontal));

    // Layout preview
    let preview = LayoutPreviewWidget::new(shared_state.clone(), layout_mode.clone(), custom_template.clone());
    let preview_widget = preview.widget();
    preview_widget.set_vexpand(true);
    preview_widget.set_hexpand(true);
    detail_box.append(preview_widget);

    detail_box.append(&gtk4::Separator::new(Orientation::Horizontal));

    // Status bar
    let status_bar = StatusBar::new(shared_state.clone());
    detail_box.append(status_bar.widget());

    // --- Toolbar / Header bar ---
    let header = adw::HeaderBar::new();
    header.set_title_widget(None::<&gtk4::Widget>);
    let title_label = gtk4::Label::new(Some("Quip"));
    title_label.add_css_class("heading");
    header.pack_start(&title_label);

    let arrange_button = gtk4::Button::with_label("Arrange");
    arrange_button.add_css_class("suggested-action");
    let wb = window_backend.clone();
    let ss = shared_state.clone();
    let lm = layout_mode.clone();
    let ct = custom_template.clone();
    arrange_button.connect_clicked(move |_| {
        arrange_windows(&ss, &*wb, &lm.borrow(), &ct.borrow());
    });
    header.pack_end(&arrange_button);

    // Settings button
    // --- Create shared PINManager ---
    let pin_manager = crate::services::pin_manager::PINManager::new();

    let settings_button = gtk4::Button::from_icon_name("emblem-system-symbolic");
    settings_button.set_tooltip_text(Some("Settings"));
    header.pack_end(&settings_button);

    main_box.append(&sidebar_frame);
    main_box.append(&gtk4::Separator::new(Orientation::Vertical));
    main_box.append(&detail_box);

    let toolbar_view = adw::ToolbarView::new();
    toolbar_view.add_top_bar(&header);
    toolbar_view.set_content(Some(&main_box));
    window.set_content(Some(&toolbar_view));

    // --- TTS state ---
    // Only the phone-selected window gets TTS synthesis
    let client_selected_window: Rc<RefCell<Option<String>>> = Rc::new(RefCell::new(None));
    // Windows that need to see Claude go busy before TTS fires (prevents stale-response readback)
    let pending_input: Rc<RefCell<HashSet<String>>> = Rc::new(RefCell::new(HashSet::new()));
    // Per-window TTS session id. Persists across delta chunks within a single
    // response turn so the phone queues them instead of cancelling earlier
    // chunks. Rotated on stt_started so the next response gets a fresh id.
    let tts_session_ids: Rc<RefCell<HashMap<String, String>>> = Rc::new(RefCell::new(HashMap::new()));

    // Start Kokoro TTS daemon if available
    let kokoro_tts: Rc<Option<crate::services::KokoroTTS>> = Rc::new(
        if crate::services::kokoro_tts::KokoroTTS::is_available() {
            let tts = crate::services::KokoroTTS::new();
            tts.preload();
            tracing::info!("Kokoro TTS available, daemon pre-warming");
            Some(tts)
        } else {
            tracing::info!("Kokoro TTS not available (no venv or script)");
            None
        }
    );

    // --- Start background services ---
    let (broadcast_tx, runtime_cmd_tx, push_service, whisper_service, connection_log) =
        start_services(
            shared_state.clone(), window_backend.clone(), input_backend.clone(), pin_manager.clone(),
            client_selected_window.clone(), pending_input.clone(), tts_session_ids.clone(),
        );
    let push_for_timer = Arc::clone(&push_service);
    let push_for_settings = Arc::clone(&push_service);
    let whisper_for_settings = Arc::clone(&whisper_service);
    let connection_log_for_settings = Arc::clone(&connection_log);

    // Wire the settings button now that we have the runtime command channel
    let ss_settings = shared_state.clone();
    let win_ref = window.clone();
    let pin_for_settings = pin_manager.clone();
    let cmd_tx_for_settings = runtime_cmd_tx.clone();
    settings_button.connect_clicked(move |_| {
        super::settings_dialog::show_settings(
            &win_ref, &ss_settings, &pin_for_settings, &cmd_tx_for_settings,
            &whisper_for_settings, &push_for_settings, &connection_log_for_settings,
        );
    });

    // --- Periodic refresh ---
    let wb_timer = window_backend.clone();
    let ss_timer = shared_state.clone();
    let ib_timer = input_backend.clone();
    let sidebar_refresh = sidebar_widget.clone();
    let preview_refresh = preview.clone();
    let status_refresh = status_bar.clone();
    let broadcast_tx_timer = broadcast_tx.clone();
    let output_high_water: Rc<RefCell<HashMap<String, String>>> = Rc::new(RefCell::new(HashMap::new()));
    let output_hw_timer = output_high_water.clone();
    let pi_timer = pending_input.clone();
    let tts_sid_timer = tts_session_ids.clone();
    let kokoro_timer = kokoro_tts.clone();
    let whisper_for_timer = Arc::clone(&whisper_service);
    glib::timeout_add_local(std::time::Duration::from_secs(2), move || {
        let changes = {
            let mut state = ss_timer.write().unwrap();
            state.refresh_windows(&*wb_timer);
            state.refresh_subtitles();
            state.state_detector.poll_all()
        };

        // Broadcast state changes and output deltas
        if !changes.is_empty() {
            tracing::info!("state_detector changes: {:?}", changes);
        }
        for (window_id, new_state) in &changes {
            let state_str = match new_state {
                crate::protocol::types::TerminalState::WaitingForInput => "waiting_for_input",
                crate::protocol::types::TerminalState::Neutral => "neutral",
                crate::protocol::types::TerminalState::SttActive => "stt_active",
            };

            // Clear pending-input when Claude goes busy
            if matches!(new_state, crate::protocol::types::TerminalState::Neutral) {
                let mut pi = pi_timer.borrow_mut();
                if pi.remove(window_id) {
                    tracing::info!("pendingInput cleared for {} — Claude is processing", window_id);
                }
            }

            // Send state_change message
            let msg = crate::protocol::messages::StateChangeMessage::new(
                window_id.clone(), state_str.to_string(),
            );
            if let Some(json) = encode_message(&msg) {
                let _ = broadcast_tx_timer.try_send(json);
            }

            // Fire APNs push when Claude transitions to waiting. This is the
            // "claude is waiting on you" buzz on the iPhone. The push service
            // honors per-device prefs (paused / quiet hours / banner toggle)
            // and 30s debounces per (window, device) so oscillations don't
            // pile up. No-ops when no APNs client is configured.
            if matches!(new_state, crate::protocol::types::TerminalState::WaitingForInput) {
                let state = ss_timer.read().unwrap();
                if let Some(w) = state.windows.iter().find(|w| w.id == *window_id) {
                    let title = if !w.subtitle.is_empty() { w.subtitle.clone() } else { w.name.clone() };
                    drop(state);
                    let svc = Arc::clone(&push_for_timer);
                    let wid = window_id.clone();
                    std::thread::spawn(move || {
                        svc.send_for_window_state(&wid, &title, "is waiting for you");
                    });
                }
            }

            // On transition to waiting_for_input, send output delta + TTS
            if matches!(new_state, crate::protocol::types::TerminalState::WaitingForInput) {
                // Skip if still waiting for Claude to process our input
                if pi_timer.borrow().contains(window_id) {
                    tracing::info!("TTS suppressed: {} still pending input response", window_id);
                    continue;
                }
                tracing::info!("TTS path entered for {}", window_id);

                let state = ss_timer.read().unwrap();
                if let Some(w) = state.windows.iter().find(|w| w.id == *window_id) {
                    let window_name = w.name.clone();
                    let wid = w.window_id;
                    let pid = w.pid;
                    let title = w.name.clone();
                    let app_class = w.app_class.clone();
                    drop(state);
                    tracing::info!("TTS: reading content for window {}", window_id);
                    let read_result = ib_timer.read_content_with_hints(wid, pid, &title, &app_class);
                    if let Err(ref e) = read_result {
                        tracing::warn!("TTS: read_content failed for {}: {}", window_id, e);
                    }
                    if let Ok(content) = read_result {
                        tracing::info!("TTS: got {} bytes of content for {}", content.len(), window_id);
                        let mut hw = output_hw_timer.borrow_mut();

                        // Compute delta: first call seeds the mark, returns empty
                        let delta = if !hw.contains_key(window_id) {
                            // First time — seed, don't TTS old content
                            hw.insert(window_id.clone(), content.clone());
                            String::new()
                        } else {
                            let prev = hw.get(window_id).cloned().unwrap_or_default();
                            hw.insert(window_id.clone(), content.clone());
                            if content == prev {
                                String::new()
                            } else {
                                // Take last 25 lines — Python filter strips UI chrome
                                let lines: Vec<&str> = content.lines().collect();
                                let start = lines.len().saturating_sub(25);
                                lines[start..].join("\n").trim().to_string()
                            }
                        };

                        tracing::info!("TTS: delta is {} bytes for {}", delta.len(), window_id);
                        if !delta.is_empty() {
                            // Broadcast output_delta
                            let msg = crate::protocol::messages::OutputDeltaMessage::new(
                                window_id.clone(), window_name.clone(), delta.clone(), true,
                            );
                            if let Some(json) = encode_message(&msg) {
                                let _ = broadcast_tx_timer.try_send(json);
                            }

                            // Trigger TTS synthesis for any window with new output
                            if let Some(tts) = kokoro_timer.as_ref() {
                                tracing::info!("TTS: calling synthesize for {}", window_id);
                                // Reuse the existing session id for this window if one
                                // is active — the phone queues chunks with the same
                                // session id instead of cancelling earlier ones.
                                // Rotated to a fresh id on stt_started so a new user
                                // turn gets a clean break.
                                let session_id = {
                                    let mut map = tts_sid_timer.borrow_mut();
                                    map.entry(window_id.clone())
                                        .or_insert_with(|| uuid::Uuid::new_v4().to_string())
                                        .clone()
                                };
                                let wid_tts = window_id.clone();
                                let wname_tts = window_name.clone();
                                let btx = broadcast_tx_timer.clone();
                                let sid = session_id.clone();
                                let sequence = Arc::new(std::sync::atomic::AtomicU32::new(0));
                                let seq_chunk = sequence.clone();

                                let wid_c = wid_tts.clone();
                                let wname_c = wname_tts.clone();
                                let sid_c = sid.clone();
                                let btx_c = btx.clone();

                                tts.synthesize(
                                    delta,
                                    move |wav_data| {
                                        use base64::Engine as _;
                                        let b64 = base64::engine::general_purpose::STANDARD
                                            .encode(&wav_data);
                                        let seq = seq_chunk.fetch_add(1, Ordering::Relaxed);
                                        let msg = TTSAudioMessage::chunk(
                                            wid_c.clone(), wname_c.clone(),
                                            sid_c.clone(), seq, b64,
                                        );
                                        if let Some(json) = encode_message(&msg) {
                                            let _ = btx_c.try_send(json);
                                        }
                                    },
                                    move || {
                                        let seq = sequence.load(Ordering::Relaxed);
                                        let msg = TTSAudioMessage::final_marker(
                                            wid_tts.clone(), wname_tts.clone(),
                                            sid.clone(), seq,
                                        );
                                        if let Some(json) = encode_message(&msg) {
                                            let _ = btx.try_send(json);
                                        }
                                    },
                                );
                            }
                        }
                    }
                }
            }
        }

        // Claude-mode scan. Read the terminal-content tail for every window
        // we've identified as running Claude and stash the detected mode in
        // shared state. build_layout_update reads from there, so the iOS app
        // sees mode pips on the next layout broadcast.
        {
            let state = ss_timer.read().unwrap();
            let claude_windows: Vec<(String, u64, u32, String, String)> = state
                .windows
                .iter()
                .filter(|w| w.is_enabled && state.state_detector.windows_with_claude.contains(&w.id))
                .map(|w| (w.id.clone(), w.window_id, w.pid, w.name.clone(), w.app_class.clone()))
                .collect();
            drop(state);

            let mut detected: Vec<(String, Option<crate::protocol::messages::ClaudeMode>)> = Vec::new();
            for (id, wid, pid, title, app_class) in &claude_windows {
                if let Ok(content) = ib_timer.read_content_with_hints(*wid, *pid, title, app_class) {
                    let mode = crate::services::claude_mode::detect_default(&content);
                    detected.push((id.clone(), mode));
                }
            }
            if !detected.is_empty() {
                let mut state = ss_timer.write().unwrap();
                for (id, mode) in detected {
                    match mode {
                        Some(m) => { state.claude_modes.insert(id, m); }
                        None => { state.claude_modes.remove(&id); }
                    }
                }
            }
        }

        // Periodic permissions probe — feeds the iOS perms Live Activity and
        // the in-app perms sheet. Mirrors PermissionProbeService on Mac. Cheap
        // (which/dbus-send), so running every 2s is fine.
        if let Some(json) = encode_message(
            &crate::services::permission_probe::PermissionProbe::probe(),
        ) {
            let _ = broadcast_tx_timer.try_send(json);
        }

        // Project-directories broadcast — phone's "+" picker shows the
        // expanded project list. We broadcast every tick (cheap, ~µs) so
        // freshly-connected clients see it within 2s without us needing
        // any new "client-authenticated" plumbing.
        let directories = {
            let state = ss_timer.read().unwrap();
            state.settings.directories.expanded()
        };
        let proj_msg = crate::protocol::messages::ProjectDirectoriesMessage::new(directories);
        if let Some(json) = encode_message(&proj_msg) {
            let _ = broadcast_tx_timer.try_send(json);
        }

        // Whisper status — same rebroadcast pattern. Without this, a freshly
        // connected iPhone never sees the Ready transition (model usually
        // loads before the phone connects), so selectPTTPath stays on the
        // local recognizer and the Linux-side whisper transcription is never
        // exercised.
        let ws_msg = crate::protocol::messages::WhisperStatusMessage::new(
            whisper_for_timer.current_state(),
        );
        if let Some(json) = encode_message(&ws_msg) {
            let _ = broadcast_tx_timer.try_send(json);
        }

        sidebar_refresh.refresh();
        preview_refresh.queue_draw();
        status_refresh.refresh();
        glib::ControlFlow::Continue
    });

    window.present();
}

fn arrange_windows(
    shared_state: &SharedState,
    backend: &dyn platform::traits::WindowBackend,
    layout_mode: &LayoutMode,
    custom_template: &CustomLayoutTemplate,
) {
    let state = shared_state.read().unwrap();
    let enabled: Vec<_> = state.enabled_windows();
    if enabled.is_empty() {
        return;
    }

    let display = state.displays.iter().find(|d| d.is_primary)
        .or_else(|| state.displays.first());
    let screen = match display {
        Some(d) => d.frame,
        None => {
            tracing::warn!("No display available for arrangement");
            return;
        }
    };

    let frames = match layout_mode {
        LayoutMode::Custom => custom_template.frames(enabled.len()),
        _ => LayoutCalculator::calculate(*layout_mode, enabled.len()),
    };

    // Collect all window moves
    let mut moves: Vec<(u64, i32, i32, u32, u32)> = Vec::new();
    for (i, window) in enabled.iter().enumerate() {
        if i >= frames.len() {
            break;
        }
        let frame = &frames[i];
        let x = screen.x + (frame.x * screen.width as f64) as i32;
        let y = screen.y + (frame.y * screen.height as f64) as i32;
        let w = (frame.width * screen.width as f64) as u32;
        let h = (frame.height * screen.height as f64) as u32;
        moves.push((window.window_id, x, y, w, h));
    }

    // Try batch move first (KDE KWin scripting benefits from batching)
    if let Err(_) = backend.batch_move_resize(&moves) {
        // Fall back to individual moves
        for &(wid, x, y, w, h) in &moves {
            if let Err(e) = backend.move_resize_window(wid, x, y, w, h) {
                tracing::warn!("Failed to arrange window: {e}");
            }
        }
    }

    tracing::info!("Arranged {} windows", enabled.len());
}

/// Start the Cloudflare tunnel and record its state/URLs into SharedState.
async fn tunnel_start(
    tunnel: &mut crate::services::cloudflare_tunnel::CloudflareTunnel,
    port: u16,
    shared_state: &SharedState,
) {
    {
        let mut state = shared_state.write().unwrap();
        state.tunnel_running = true;
    }
    match tunnel.start(port).await {
        Ok(()) => {
            tracing::info!("Cloudflare tunnel started: {}", tunnel.ws_url());
            let mut state = shared_state.write().unwrap();
            state.tunnel_url = tunnel.public_url().to_string();
            state.tunnel_ws_url = tunnel.ws_url().to_string();
        }
        Err(e) => {
            tracing::warn!("Cloudflare tunnel failed: {e}");
            let mut state = shared_state.write().unwrap();
            state.tunnel_running = false;
        }
    }
}

/// Stop the Cloudflare tunnel and clear its recorded URLs.
fn tunnel_stop(
    tunnel: &mut crate::services::cloudflare_tunnel::CloudflareTunnel,
    shared_state: &SharedState,
) {
    tunnel.stop();
    let mut state = shared_state.write().unwrap();
    state.tunnel_running = false;
    state.tunnel_url.clear();
    state.tunnel_ws_url.clear();
}

/// Switch between Cloudflare tunnel, Tailscale, and local-only based on the
/// given network mode. Safe to call repeatedly — each branch is idempotent on
/// its own dependencies.
async fn apply_network_mode(
    mode: NetworkMode,
    tunnel: &std::sync::Arc<tokio::sync::Mutex<crate::services::cloudflare_tunnel::CloudflareTunnel>>,
    tailscale: &std::sync::Arc<tokio::sync::Mutex<TailscaleService>>,
    port: u16,
    shared_state: &SharedState,
    ws_server: &Arc<crate::services::ws_server::WsServer>,
) {
    reload_require_auth(ws_server, shared_state);

    match mode {
        NetworkMode::CloudflareTunnel => {
            TailscaleService::stop(tailscale.clone(), shared_state.clone()).await;
            let mut t = tunnel.lock().await;
            tunnel_start(&mut t, port, shared_state).await;
        }
        NetworkMode::Tailscale => {
            {
                let mut t = tunnel.lock().await;
                tunnel_stop(&mut t, shared_state);
            }
            TailscaleService::refresh(tailscale.clone(), shared_state.clone(), port).await;
        }
        NetworkMode::LocalOnly => {
            {
                let mut t = tunnel.lock().await;
                tunnel_stop(&mut t, shared_state);
            }
            TailscaleService::stop(tailscale.clone(), shared_state.clone()).await;
        }
    }
}

/// Reload require_auth on the WebSocket server from current settings.
/// New connections will see the new value; existing authenticated clients are unaffected.
fn reload_require_auth(
    ws_server: &Arc<crate::services::ws_server::WsServer>,
    shared_state: &SharedState,
) {
    let require_auth = {
        let state = shared_state.read().unwrap();
        state.settings.general.require_pin_for_local
    };
    ws_server.set_require_auth(require_auth);
    tracing::info!("WebSocket require_auth updated to {require_auth}");
}

/// Returns a broadcast sender (for GTK → WS clients) and a runtime command sender
/// (for the settings dialog → tokio runtime live-reconfiguration).
fn start_services(
    shared_state: SharedState,
    window_backend: Arc<dyn platform::traits::WindowBackend>,
    input_backend: Arc<dyn platform::traits::InputBackend>,
    pin_manager: crate::services::pin_manager::PINManager,
    client_selected_window: Rc<RefCell<Option<String>>>,
    pending_input: Rc<RefCell<HashSet<String>>>,
    tts_session_ids: Rc<RefCell<HashMap<String, String>>>,
) -> (
    async_channel::Sender<String>,
    async_channel::Sender<RuntimeCommand>,
    Arc<crate::services::push_service::PushService>,
    Arc<crate::services::whisper_service::WhisperService>,
    Arc<crate::services::connection_log::ConnectionLog>,
) {
    let port = {
        let state = shared_state.read().unwrap();
        state.settings.general.websocket_port
    };
    let bonjour_name = {
        let state = shared_state.read().unwrap();
        state.settings.general.bonjour_name.clone()
    };

    // Audit logger for remote command logging
    let audit_logger = crate::services::audit_logger::AuditLogger::new();

    // Channel for incoming WS messages -> GTK thread
    let (gtk_tx, gtk_rx) = async_channel::bounded::<String>(256);
    let (msg_tx, msg_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    // Channel for outbound broadcasts from GTK -> tokio (state changes, TTS)
    let (broadcast_tx, broadcast_rx) = async_channel::bounded::<String>(64);
    // Channel for runtime reconfiguration commands from settings dialog -> tokio
    let (runtime_cmd_tx, runtime_cmd_rx) = async_channel::bounded::<RuntimeCommand>(16);

    // WebSocket server only handles direct (local) connections.
    // Tunnel clients get auth_required from CloudflareTunnel independently.
    // Local connections only require auth if require_pin_for_local is set.
    let require_auth = {
        let state = shared_state.read().unwrap();
        state.settings.general.require_pin_for_local
    };

    // Create WsServer before spawning the background thread so it can be shared
    let ws_server = Arc::new(crate::services::ws_server::WsServer::with_auth(port, msg_tx, pin_manager, require_auth));

    // Tokio runtime on background thread
    let rt = tokio::runtime::Runtime::new().expect("failed to create tokio runtime");
    let ss_bg = shared_state.clone();
    let ws_bg = ws_server.clone();

    std::thread::spawn(move || {
        rt.block_on(async move {
            let mut msg_rx = msg_rx;
            let ws_server = ws_bg;
            let ws_clone = ws_server.clone();
            tokio::spawn(async move {
                ws_clone.run().await;
            });

            // 10s heartbeat ping. Phones notice a dead daemon within ~15s
            // (one ping interval + send timeout). Mirrors Mac's heartbeat.
            let ws_heartbeat = ws_server.clone();
            tokio::spawn(async move {
                let mut interval = tokio::time::interval(std::time::Duration::from_secs(10));
                interval.tick().await; // skip the immediate first tick
                loop {
                    interval.tick().await;
                    ws_heartbeat.heartbeat_ping().await;
                }
            });

            {
                let mut state = ss_bg.write().unwrap();
                state.ws_running = true;
            }

            // Start mDNS advertiser
            match crate::services::mdns_advertiser::MdnsAdvertiser::start(&bonjour_name, port) {
                Ok(_advertiser) => {
                    let mut state = ss_bg.write().unwrap();
                    state.mdns_advertising = true;
                    tracing::info!("mDNS advertising started");
                    // Keep advertiser alive by leaking it (runs until process exits)
                    std::mem::forget(_advertiser);
                }
                Err(e) => tracing::warn!("Failed to start mDNS: {e}"),
            }

            // Command handler: owns the Cloudflare tunnel and the Tailscale
            // service across its lifetime so both can be started, stopped, and
            // restarted at runtime in response to settings changes.
            let ss_tunnel = ss_bg.clone();
            let ws_for_cmds = ws_server.clone();
            tokio::spawn(async move {
                let tunnel = std::sync::Arc::new(tokio::sync::Mutex::new(
                    crate::services::cloudflare_tunnel::CloudflareTunnel::new(),
                ));
                let tailscale = std::sync::Arc::new(tokio::sync::Mutex::new(
                    TailscaleService::new(),
                ));

                // Apply whatever mode is persisted in settings on startup.
                let initial_mode = {
                    let state = ss_tunnel.read().unwrap();
                    state.settings.network_mode()
                };
                apply_network_mode(
                    initial_mode,
                    &tunnel,
                    &tailscale,
                    port,
                    &ss_tunnel,
                    &ws_for_cmds,
                )
                .await;

                // Health check: every 60s, restart tunnel if process died.
                // Only touches the tunnel when cloudflare mode is active.
                let tunnel_health = tunnel.clone();
                let ss_health = ss_tunnel.clone();
                tokio::spawn(async move {
                    let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));
                    loop {
                        interval.tick().await;
                        let mode = {
                            let state = ss_health.read().unwrap();
                            state.settings.network_mode()
                        };
                        if !matches!(mode, NetworkMode::CloudflareTunnel) {
                            continue;
                        }
                        let needs_restart = {
                            let mut t = tunnel_health.lock().await;
                            if t.is_running() {
                                !t.check_health()
                            } else {
                                false
                            }
                        };
                        if needs_restart {
                            tracing::info!("Health check: tunnel process died, restarting in 3s");
                            tokio::time::sleep(std::time::Duration::from_secs(3)).await;
                            let mut t = tunnel_health.lock().await;
                            tunnel_start(&mut t, port, &ss_health).await;
                        }
                    }
                });

                // Handle live reconfiguration commands from the settings dialog.
                while let Ok(cmd) = runtime_cmd_rx.recv().await {
                    match cmd {
                        RuntimeCommand::SetNetworkMode(mode) => {
                            tracing::info!("Runtime: switching to network mode {:?}", mode);
                            apply_network_mode(
                                mode,
                                &tunnel,
                                &tailscale,
                                port,
                                &ss_tunnel,
                                &ws_for_cmds,
                            )
                            .await;
                        }
                        RuntimeCommand::RefreshTailscale => {
                            TailscaleService::refresh(
                                tailscale.clone(),
                                ss_tunnel.clone(),
                                port,
                            )
                            .await;
                        }
                        RuntimeCommand::ReloadAuth => {
                            reload_require_auth(&ws_for_cmds, &ss_tunnel);
                        }
                    }
                }
            });

            // Broadcast layout periodically
            let ss_broadcast = ss_bg.clone();
            let ws_broadcast = ws_server.clone();
            tokio::spawn(async move {
                let mut interval = tokio::time::interval(std::time::Duration::from_secs(2));
                loop {
                    interval.tick().await;
                    if ws_broadcast.client_count() == 0 {
                        continue;
                    }
                    let update = {
                        let state = ss_broadcast.read().unwrap();
                        state.build_layout_update()
                    };
                    if let Some(json) = encode_message(&update) {
                        ws_broadcast.broadcast(&json).await;
                    }
                    // Update client count
                    let count = ws_broadcast.client_count();
                    let mut state = ss_broadcast.write().unwrap();
                    state.ws_client_count = count;
                }
            });

            // Forward outbound broadcasts from GTK thread
            let ws_outbound = ws_server.clone();
            tokio::spawn(async move {
                while let Ok(json) = broadcast_rx.recv().await {
                    ws_outbound.broadcast(&json).await;
                }
            });

            // Forward incoming messages to GTK thread
            while let Some(msg) = msg_rx.recv().await {
                let _ = gtk_tx.send(msg).await;
            }
        });
    });

    // Handle incoming messages on GTK thread.
    // Responses go through broadcast_tx (async_channel) → tokio, NOT through
    // ws_server.broadcast() directly, because the tokio WebSocket sink can't
    // be driven from the glib event loop — that would deadlock.
    let ss_handler = shared_state.clone();
    let ib_handler = input_backend.clone();
    let wb_handler = window_backend.clone();
    let btx_handler = broadcast_tx.clone();
    let al_handler = audit_logger.clone();
    let csw_handler = client_selected_window;
    let pi_handler = pending_input;
    let tts_handler = tts_session_ids;
    // Whisper PTT — local transcription. Lazily downloads + loads its model
    // on first audio chunk; broadcasts whisper_status updates so the iPhone
    // knows whether the remote-recognizer path is viable.
    let whisper = crate::services::whisper_service::WhisperService::new(broadcast_tx.clone());
    whisper.ensure_model_async();
    let whisper_handler = Arc::clone(&whisper);
    let whisper_returned = whisper;

    // Push service — APNs registry + per-device prefs. Pushes don't fire
    // until set_apns_client is called from the settings UI with a valid
    // .p8 + key/team/bundle ids.
    let push_service = crate::services::push_service::PushService::new();
    let push_handler = Arc::clone(&push_service);
    let push_returned = Arc::clone(&push_service);

    // Phone-prefs registry — receives preferences_snapshot, replies to
    // preferences_request. Persists to ~/.config/quip/phone-prefs.json.
    let prefs_store = std::sync::Arc::new(
        crate::services::preferences_store::PreferencesStore::default_production(),
    );
    let prefs_handler = Arc::clone(&prefs_store);

    glib::spawn_future_local(async move {
        while let Ok(json) = gtk_rx.recv().await {
            handle_incoming_message(
                &json, &ss_handler, &*wb_handler, &*ib_handler, &btx_handler, &al_handler,
                &csw_handler, &pi_handler, &tts_handler, &whisper_handler, &push_handler,
                &prefs_handler,
            );
        }
    });

    let connection_log_returned = Arc::clone(&ws_server.connection_log);
    (broadcast_tx, runtime_cmd_tx, push_returned, whisper_returned, connection_log_returned)
}

/// Trim trailing whitespace-only lines from a terminal-content scrape.
/// Mirrors Mac's `while let last = lines.last, last.trimmingCharacters
/// (in: .whitespaces).isEmpty` strip from the request_content path.
fn strip_trailing_blank_lines(content: &str) -> String {
    let mut lines: Vec<&str> = content.split('\n').collect();
    while lines.last().map(|l| l.trim().is_empty()).unwrap_or(false) {
        lines.pop();
    }
    lines.join("\n")
}

#[cfg(test)]
mod scrape_tests {
    use super::strip_trailing_blank_lines;

    #[test]
    fn strips_trailing_blanks() {
        let input = "first\nsecond\n   \n\n  \n";
        assert_eq!(strip_trailing_blank_lines(input), "first\nsecond");
    }

    #[test]
    fn preserves_internal_blanks() {
        let input = "first\n\nsecond\n";
        assert_eq!(strip_trailing_blank_lines(input), "first\n\nsecond");
    }

    #[test]
    fn handles_all_blanks() {
        assert_eq!(strip_trailing_blank_lines("\n\n\n"), "");
    }

    #[test]
    fn handles_empty() {
        assert_eq!(strip_trailing_blank_lines(""), "");
    }
}

/// Broadcast an ErrorMessage so the phone shows a red toast instead of
/// the action silently no-oping. Used on dead-window targets and other
/// recoverable failures during message handling.
fn return_error(broadcast_tx: &async_channel::Sender<String>, reason: String) {
    let msg = crate::protocol::messages::ErrorMessage::new(reason);
    if let Some(json) = encode_message(&msg) {
        let _ = broadcast_tx.try_send(json);
    }
}

fn handle_incoming_message(
    json: &str,
    shared_state: &SharedState,
    window_backend: &dyn platform::traits::WindowBackend,
    input_backend: &dyn platform::traits::InputBackend,
    broadcast_tx: &async_channel::Sender<String>,
    audit_logger: &crate::services::audit_logger::AuditLogger,
    client_selected_window: &Rc<RefCell<Option<String>>>,
    pending_input: &Rc<RefCell<HashSet<String>>>,
    tts_session_ids: &Rc<RefCell<HashMap<String, String>>>,
    whisper: &Arc<crate::services::whisper_service::WhisperService>,
    push: &Arc<crate::services::push_service::PushService>,
    prefs_store: &Arc<crate::services::preferences_store::PreferencesStore>,
) {
    use message_router::IncomingAction;

    tracing::info!("Incoming WS message: {json}");
    let action = match message_router::parse_incoming(json) {
        Some(a) => {
            tracing::info!("Parsed action: {a:?}");
            a
        }
        None => {
            tracing::warn!("Failed to parse incoming message");
            return;
        }
    };

    // Build broadcast payload inside the lock, then send after dropping it
    // to avoid deadlock (broadcast awaits a tokio Mutex while we hold the RwLock)
    let broadcast_json = {
        let mut state = shared_state.write().unwrap();

        match action {
            IncomingAction::SelectWindow(window_id) => {
                // Phone-side selection is just a view choice — do NOT pull
                // host focus. Host user may be working in a different window;
                // focus only moves when input is actually being delivered
                // (and even then only on the OS-input path, where the input
                // backend focuses internally — the Konsole D-Bus path leaves
                // focus alone entirely).
                *client_selected_window.borrow_mut() = Some(window_id);
                None
            }
            IncomingAction::SendText { window_id, text, press_return } => {
                audit_logger.log("send_text", "ws-client", &text);
                tracing::info!("SendText: window_id={window_id}, text={text}, press_return={press_return}");
                let hint = state.windows.iter().find(|w| w.id == window_id).map(|w| {
                    (w.window_id, w.pid, w.name.clone(), w.app_class.clone())
                });
                if let Some((wid, pid, title, app_class)) = hint {
                    tracing::info!("Found window, target wid={wid} pid={pid} class={app_class}");
                    // Don't pre-focus here. The input backend focuses itself
                    // on the OS-input path (ydotool/wtype need the window
                    // active), and skips focus entirely on the Konsole D-Bus
                    // path. That keeps host focus steady for the common case.
                    if let Err(e) = input_backend.send_text_with_hints(
                        wid, &text, press_return, pid, &title, &app_class,
                    ) {
                        tracing::warn!("Failed to send text to {window_id}: {e}");
                        return_error(broadcast_tx, format!("send_text failed: {e}"));
                    } else {
                        tracing::info!("Text sent successfully");
                    }
                } else {
                    tracing::warn!("Window not found for id: {window_id}");
                    return_error(broadcast_tx, format!("send_text: window {window_id} not found"));
                }
                None
            }
            IncomingAction::QuickAction { window_id, action } => {
                audit_logger.log("quick_action", "ws-client", &action);
                let hint = state.windows.iter().find(|w| w.id == window_id).map(|w| {
                    (w.window_id, w.pid, w.name.clone(), w.app_class.clone(), w.is_enabled)
                });
                if hint.is_none() {
                    return_error(
                        broadcast_tx,
                        format!("quick_action '{action}': window {window_id} not found"),
                    );
                }
                if let Some((wid, pid, title, app_class, enabled)) = hint {
                    // Same reasoning as SendText — let the input backend
                    // decide whether it needs focus, so the D-Bus path stays
                    // focus-free.
                    let key = |k: &str| {
                        if let Err(e) = input_backend.send_keystroke_with_hints(wid, k, pid, &title, &app_class) {
                            tracing::warn!("send_keystroke '{k}' failed for window {wid}: {e}");
                        }
                    };
                    let txt = |t: &str, ret: bool| {
                        if let Err(e) = input_backend.send_text_with_hints(wid, t, ret, pid, &title, &app_class) {
                            tracing::warn!("send_text failed for window {wid}: {e}");
                        }
                    };
                    // Claude Code mode cycling — read current mode from the
                    // shared state's claude_modes map, compute press count,
                    // send Shift+Tab that many times. Mac wires this the same
                    // way (QuipMacApp.swift cycleClaudeMode).
                    let cycle_to = |target: crate::protocol::messages::ClaudeMode| {
                        let current = state
                            .claude_modes
                            .get(&window_id)
                            .copied()
                            .unwrap_or(crate::protocol::messages::ClaudeMode::Normal);
                        let presses = crate::protocol::messages::ClaudeMode::shift_tab_presses(
                            current, target,
                        );
                        for _ in 0..presses {
                            key("shift+tab");
                        }
                    };

                    match action.as_str() {
                        "press_return" => key("return"),
                        "press_ctrl_c" => key("ctrl+c"),
                        "press_ctrl_d" => key("ctrl+d"),
                        "press_escape" => key("escape"),
                        "press_tab" => key("tab"),
                        "press_shift_tab" => key("shift+tab"),
                        "press_backspace" => key("backspace"),
                        // Ctrl+U — readline "kill to start of line"; wipes prompt.
                        "clear_input" => key("ctrl+u"),
                        "set_plan_mode" => cycle_to(crate::protocol::messages::ClaudeMode::Plan),
                        "set_auto_accept_mode" => cycle_to(crate::protocol::messages::ClaudeMode::AutoAccept),
                        "set_normal_mode" => cycle_to(crate::protocol::messages::ClaudeMode::Normal),
                        "press_y" => key("y"),
                        "press_n" => key("n"),
                        "clear_terminal" => txt("/clear", true),
                        "restart_claude" => {
                            key("ctrl+c");
                            std::thread::sleep(std::time::Duration::from_millis(500));
                            txt("claude", true);
                        }
                        "toggle_enabled" => {
                            state.toggle_window(&window_id, !enabled);
                        }
                        _ => {}
                    }
                }
                None
            }
            IncomingAction::SttStarted(window_id) => {
                *client_selected_window.borrow_mut() = Some(window_id.clone());
                pending_input.borrow_mut().insert(window_id.clone());
                // New user input → next response is a new turn, so rotate the
                // TTS session id. That interrupts any lingering audio from the
                // prior answer on the phone.
                tts_session_ids.borrow_mut().remove(&window_id);
                state.state_detector.set_stt_active(&window_id);
                if let Some(w) = state.windows.iter().find(|w| w.id == window_id) {
                    crate::services::terminal_color::set_background_color(
                        w.pid,
                        &state.settings.colors.stt_active,
                    );
                }
                // Broadcast the state change so all viewers (including the
                // one that triggered STT) paint the window as stt_active.
                // poll_all skips STT windows so it will never emit this.
                let msg = crate::protocol::messages::StateChangeMessage::new(
                    window_id.clone(),
                    "stt_active".into(),
                );
                encode_message(&msg)
            }
            IncomingAction::SttEnded(window_id) => {
                state.state_detector.clear_stt(&window_id);
                if let Some(w) = state.windows.iter().find(|w| w.id == window_id) {
                    crate::services::terminal_color::reset_background_color(w.pid);
                }
                let msg = crate::protocol::messages::StateChangeMessage::new(
                    window_id.clone(),
                    "neutral".into(),
                );
                encode_message(&msg)
            }
            IncomingAction::DuplicateWindow(source_window_id) => {
                // Spawn a fresh terminal in the same directory as the source.
                let source_dir = state
                    .windows
                    .iter()
                    .find(|w| w.id == source_window_id)
                    .map(|w| w.subtitle.clone())
                    .filter(|s| !s.is_empty());
                let terminal = state.settings.general.default_terminal.clone();
                drop(state);
                match source_dir {
                    Some(dir) => {
                        if let Err(e) = input_backend.spawn_terminal(&terminal, &dir) {
                            tracing::warn!("duplicate_window: spawn failed: {e}");
                            return_error(broadcast_tx, format!("spawn failed: {e}"));
                        }
                    }
                    None => {
                        return_error(
                            broadcast_tx,
                            format!("duplicate_window: source window {source_window_id} not found"),
                        );
                    }
                }
                state = shared_state.write().unwrap();
                None
            }
            IncomingAction::CloseWindow(window_id) => {
                // Send SIGTERM to the terminal app's PID. There's no portable
                // "close this window" gesture on Linux for arbitrary apps —
                // killing the process is what "Close Terminal" means here.
                audit_logger.log("close_window", "ws-client", &window_id);
                let pid = state.windows.iter().find(|w| w.id == window_id).map(|w| w.pid);
                match pid {
                    Some(p) => {
                        match nix::sys::signal::kill(
                            nix::unistd::Pid::from_raw(p as i32),
                            nix::sys::signal::Signal::SIGTERM,
                        ) {
                            Ok(()) => tracing::info!("close_window: SIGTERM sent to pid {p}"),
                            Err(e) => {
                                tracing::warn!("close_window: kill({p}) failed: {e}");
                                return_error(broadcast_tx, format!("close failed: {e}"));
                            }
                        }
                    }
                    None => {
                        return_error(
                            broadcast_tx,
                            format!("close_window: window {window_id} not found"),
                        );
                    }
                }
                None
            }
            IncomingAction::SpawnWindow(directory) => {
                let terminal = state.settings.general.default_terminal.clone();
                drop(state);
                if let Err(e) = input_backend.spawn_terminal(&terminal, &directory) {
                    tracing::warn!("spawn_window: spawn failed: {e}");
                    return_error(broadcast_tx, format!("spawn failed: {e}"));
                }
                state = shared_state.write().unwrap();
                None
            }
            IncomingAction::ArrangeWindows(layout) => {
                use crate::models::layout::LayoutMode;
                let mode = match layout.as_str() {
                    "horizontal" => LayoutMode::Columns,
                    "vertical" => LayoutMode::Rows,
                    other => {
                        return_error(broadcast_tx, format!("arrange_windows: unknown layout '{other}'"));
                        return;
                    }
                };
                drop(state);
                // Custom-template arg is unused for Columns/Rows; pass any variant.
                arrange_windows(
                    shared_state,
                    window_backend,
                    &mode,
                    &crate::models::layout::CustomLayoutTemplate::LargeLeftSmallRight,
                );
                state = shared_state.write().unwrap();
                None
            }
            IncomingAction::OpenSettingsPane(msg) => {
                tracing::info!("open_mac_settings_pane: {:?}", msg.pane);
                crate::services::settings_pane_opener::open_pane(msg.pane);
                None
            }
            IncomingAction::PreferencesSnapshot(msg) => {
                prefs_store.put(msg.device_id.clone(), msg.preferences);
                None
            }
            IncomingAction::PreferencesRequest(msg) => {
                let snapshot = prefs_store.get(&msg.device_id);
                let restore =
                    crate::protocol::messages::PreferenceRestoreMessage::new(snapshot);
                encode_message(&restore)
            }
            IncomingAction::AudioChunk(msg) => {
                whisper.handle_chunk(msg);
                None
            }
            IncomingAction::RegisterPushDevice(msg) => {
                tracing::info!("push register: token={} env={}", &msg.device_token[..8.min(msg.device_token.len())], msg.environment);
                push.register(msg);
                None
            }
            IncomingAction::PushPreferences(msg) => {
                tracing::info!("push prefs: paused={} banner={:?} qh={:?}-{:?}",
                    msg.paused, msg.banner_enabled, msg.quiet_hours_start, msg.quiet_hours_end);
                push.apply_preferences(msg);
                None
            }
            IncomingAction::ImageUpload(msg) => {
                use crate::services::image_upload::ImageUploadHandler;
                let image_id = msg.image_id.clone();
                let window_id = msg.window_id.clone();
                let hint = state.windows.iter().find(|w| w.id == window_id).map(|w| {
                    (w.window_id, w.pid, w.name.clone(), w.app_class.clone())
                });

                let handler = ImageUploadHandler::default_production();
                let response_json = match handler.save(&msg) {
                    Ok(saved) => {
                        let saved_path = saved.to_string_lossy().to_string();
                        audit_logger.log("image_upload", "ws-client", &saved_path);

                        // Paste " <path> " into the focused terminal so it joins
                        // any existing user text. No press_return — the phone
                        // sends a separate send_text/press_return after the ack
                        // (see CLAUDE.md photo-upload-spinner rule about
                        // ordering).
                        if let Some((wid, pid, title, app_class)) = hint {
                            let pasted = format!(" {saved_path} ");
                            if let Err(e) = input_backend.send_text_with_hints(
                                wid, &pasted, false, pid, &title, &app_class,
                            ) {
                                tracing::warn!("Failed to paste image path into {window_id}: {e}");
                            }
                        } else {
                            tracing::warn!("image_upload: window {window_id} not found, file saved but not pasted");
                        }

                        let ack = crate::protocol::messages::ImageUploadAckMessage::new(
                            image_id,
                            saved_path,
                        );
                        encode_message(&ack)
                    }
                    Err(e) => {
                        tracing::warn!("image_upload save failed: {e}");
                        let err = crate::protocol::messages::ImageUploadErrorMessage::new(
                            image_id,
                            e.to_string(),
                        );
                        encode_message(&err)
                    }
                };

                response_json
            }
            IncomingAction::RequestContent(window_id) => {
                if let Some(w) = state.windows.iter().find(|w| w.id == window_id) {
                    let wid = w.window_id;
                    let pid = w.pid;
                    let title = w.name.clone();
                    let app_class = w.app_class.clone();
                    // Try tmux text content first (scrollable, best UX)
                    let text_content = input_backend
                        .read_content_with_hints(wid, pid, &title, &app_class)
                        .unwrap_or_default();
                    // Strip trailing whitespace-only rows. Claude Code pads
                    // its prompt box with blank cells to wipe stale text;
                    // sent raw, those rows land at the bottom of the phone's
                    // scroll view and push the prompt off-screen.
                    let text_content = strip_trailing_blank_lines(&text_content);
                    let text_content = crate::services::secret_redactor::redact(&text_content);

                    let msg = if !text_content.is_empty() {
                        // Got text from tmux — send text only (scrollable on iOS).
                        // Extract URLs so iOS can render the tap-to-open tray.
                        let urls = crate::services::terminal_url_extractor::extract(&text_content);
                        let mut m = crate::protocol::messages::TerminalContentMessage::new(window_id, text_content);
                        if !urls.is_empty() {
                            m = m.with_urls(urls);
                        }
                        m
                    } else {
                        // No tmux — fall back to screenshot
                        match input_backend.capture_screenshot(wid) {
                            Ok(ss) => crate::protocol::messages::TerminalContentMessage::with_screenshot(
                                window_id, "(Run terminals in tmux for scrollable text)".into(), ss,
                            ),
                            Err(e) => {
                                tracing::warn!("Screenshot failed: {e}");
                                crate::protocol::messages::TerminalContentMessage::new(
                                    window_id, format!("(No tmux detected, screenshot failed: {e})"),
                                )
                            }
                        }
                    };
                    crate::protocol::messages::encode_message(&msg)
                } else {
                    let msg = crate::protocol::messages::TerminalContentMessage::new(window_id, "(Window not found)".into());
                    crate::protocol::messages::encode_message(&msg)
                }
            }
            IncomingAction::ScanITermWindows => {
                // Linux equivalent of Mac's iTerm scan: list every terminal
                // window the backend can see. is_enabled mirrors Mac's
                // "already tracked" — disabled terminals are the ones the
                // user can adopt by tapping. sessionId is the Quip composite
                // id ("{class}.{wid}"); windowNumber is the X11/Wayland id.
                let infos: Vec<crate::protocol::messages::ITermWindowInfo> = state
                    .windows
                    .iter()
                    .filter(|w| crate::platform::traits::is_terminal_class(&w.app_class))
                    .map(|w| crate::protocol::messages::ITermWindowInfo {
                        window_number: w.window_id as i64,
                        title: w.name.clone(),
                        session_id: w.id.clone(),
                        cwd: w.subtitle.clone(),
                        is_already_tracked: w.is_enabled,
                        is_miniaturized: !w.is_on_visible_screen,
                    })
                    .collect();
                tracing::info!(
                    "scan_iterm_windows: returning {} windows ({} already tracked)",
                    infos.len(),
                    infos.iter().filter(|i| i.is_already_tracked).count()
                );
                let msg = crate::protocol::messages::ITermWindowListMessage::new(infos);
                encode_message(&msg)
            }
            IncomingAction::AttachITermWindow(msg) => {
                // Match by sessionId first (Quip's composite id, exact); fall
                // back to windowNumber if the phone is talking to a slightly
                // older snapshot. Toggle enabled=true so the window starts
                // broadcasting; toggle_window persists the enabled set.
                let target_id = state
                    .windows
                    .iter()
                    .find(|w| w.id == msg.session_id)
                    .or_else(|| {
                        state
                            .windows
                            .iter()
                            .find(|w| w.window_id as i64 == msg.window_number)
                    })
                    .map(|w| w.id.clone());

                if let Some(id) = target_id {
                    state.toggle_window(&id, true);
                    tracing::info!("attach_iterm_window: enabled {id}");
                    // Push a fresh layout immediately so the phone sees the
                    // newly-attached window without waiting on the 2s timer.
                    encode_message(&state.build_layout_update())
                } else {
                    tracing::warn!(
                        "attach_iterm_window: no window matched sessionId={} windowNumber={}",
                        msg.session_id,
                        msg.window_number
                    );
                    return_error(
                        broadcast_tx,
                        format!("attach_iterm_window: window not found"),
                    );
                    None
                }
            }
        }
    }; // state lock dropped here

    if let Some(json) = broadcast_json {
        let _ = broadcast_tx.try_send(json);
    }
}
