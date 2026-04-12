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
    let (broadcast_tx, runtime_cmd_tx) = start_services(
        shared_state.clone(), window_backend.clone(), input_backend.clone(), pin_manager.clone(),
        client_selected_window.clone(), pending_input.clone(),
    );

    // Wire the settings button now that we have the runtime command channel
    let ss_settings = shared_state.clone();
    let win_ref = window.clone();
    let pin_for_settings = pin_manager.clone();
    let cmd_tx_for_settings = runtime_cmd_tx.clone();
    settings_button.connect_clicked(move |_| {
        super::settings_dialog::show_settings(&win_ref, &ss_settings, &pin_for_settings, &cmd_tx_for_settings);
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
    let kokoro_timer = kokoro_tts.clone();
    glib::timeout_add_local(std::time::Duration::from_secs(2), move || {
        let changes = {
            let mut state = ss_timer.write().unwrap();
            state.refresh_windows(&*wb_timer);
            state.refresh_subtitles();
            state.state_detector.poll_all()
        };

        // Broadcast state changes and output deltas
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

            // On transition to waiting_for_input, send output delta + TTS
            if matches!(new_state, crate::protocol::types::TerminalState::WaitingForInput) {
                // Skip if still waiting for Claude to process our input
                if pi_timer.borrow().contains(window_id) {
                    tracing::info!("TTS suppressed: {} still pending input response", window_id);
                    continue;
                }

                let state = ss_timer.read().unwrap();
                if let Some(w) = state.windows.iter().find(|w| w.id == *window_id) {
                    let window_name = w.name.clone();
                    let wid = w.window_id;
                    let pid = w.pid;
                    let title = w.name.clone();
                    let app_class = w.app_class.clone();
                    drop(state);
                    if let Ok(content) = ib_timer.read_content_with_hints(wid, pid, &title, &app_class) {
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
                                let session_id = uuid::Uuid::new_v4().to_string();
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
) -> (async_channel::Sender<String>, async_channel::Sender<RuntimeCommand>) {
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

    // Handle incoming messages on GTK thread
    let ss_handler = shared_state.clone();
    let ib_handler = input_backend.clone();
    let wb_handler = window_backend.clone();
    let ws_handler = ws_server.clone();
    let al_handler = audit_logger.clone();
    let csw_handler = client_selected_window;
    let pi_handler = pending_input;
    glib::spawn_future_local(async move {
        while let Ok(json) = gtk_rx.recv().await {
            handle_incoming_message(
                &json, &ss_handler, &*wb_handler, &*ib_handler, &ws_handler, &al_handler,
                &csw_handler, &pi_handler,
            ).await;
        }
    });

    (broadcast_tx, runtime_cmd_tx)
}

async fn handle_incoming_message(
    json: &str,
    shared_state: &SharedState,
    window_backend: &dyn platform::traits::WindowBackend,
    input_backend: &dyn platform::traits::InputBackend,
    ws_server: &crate::services::ws_server::WsServer,
    audit_logger: &crate::services::audit_logger::AuditLogger,
    client_selected_window: &Rc<RefCell<Option<String>>>,
    pending_input: &Rc<RefCell<HashSet<String>>>,
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
                *client_selected_window.borrow_mut() = Some(window_id.clone());
                state.focus_window(&window_id, window_backend);
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
                    state.focus_window(&window_id, window_backend);
                    if let Err(e) = input_backend.send_text_with_hints(
                        wid, &text, press_return, pid, &title, &app_class,
                    ) {
                        tracing::warn!("Failed to send text to {window_id}: {e}");
                    } else {
                        tracing::info!("Text sent successfully");
                    }
                } else {
                    tracing::warn!("Window not found for id: {window_id}");
                }
                None
            }
            IncomingAction::QuickAction { window_id, action } => {
                audit_logger.log("quick_action", "ws-client", &action);
                let hint = state.windows.iter().find(|w| w.id == window_id).map(|w| {
                    (w.window_id, w.pid, w.name.clone(), w.app_class.clone(), w.is_enabled)
                });
                if let Some((wid, pid, title, app_class, enabled)) = hint {
                    state.focus_window(&window_id, window_backend);
                    let key = |k: &str| {
                        let _ = input_backend.send_keystroke_with_hints(wid, k, pid, &title, &app_class);
                    };
                    let txt = |t: &str, ret: bool| {
                        let _ = input_backend.send_text_with_hints(wid, t, ret, pid, &title, &app_class);
                    };
                    match action.as_str() {
                        "press_return" => key("return"),
                        "press_ctrl_c" => key("ctrl+c"),
                        "press_ctrl_d" => key("ctrl+d"),
                        "press_escape" => key("escape"),
                        "press_tab" => key("tab"),
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
                    let text_content = crate::services::secret_redactor::redact(&text_content);

                    let msg = if !text_content.is_empty() {
                        // Got text from tmux — send text only (scrollable on iOS)
                        crate::protocol::messages::TerminalContentMessage::new(window_id, text_content)
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
        }
    }; // state lock dropped here

    if let Some(json) = broadcast_json {
        ws_server.broadcast(&json).await;
    }
}
