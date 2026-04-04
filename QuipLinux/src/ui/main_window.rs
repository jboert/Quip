use glib::clone;
use gtk4::prelude::*;
use gtk4::{self, Align, Orientation, PolicyType, ScrolledWindow};
use libadwaita as adw;
use libadwaita::prelude::*;
use std::cell::RefCell;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use crate::models::layout::{CustomLayoutTemplate, LayoutCalculator, LayoutMode};
use crate::platform;
use crate::protocol::messages::encode_message;
use crate::services::message_router;
use crate::state::{self, SharedState};

use super::layout_preview::LayoutPreviewWidget;
use super::status_bar::StatusBar;
use super::window_list::WindowListWidget;

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
    let sidebar_widget = WindowListWidget::new(shared_state.clone());
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
    let settings_button = gtk4::Button::from_icon_name("emblem-system-symbolic");
    settings_button.set_tooltip_text(Some("Settings"));
    let ss_settings = shared_state.clone();
    let win_ref = window.clone();
    let pin_for_settings = pin_manager.clone();
    settings_button.connect_clicked(move |_| {
        super::settings_dialog::show_settings(&win_ref, &ss_settings, &pin_for_settings);
    });
    header.pack_end(&settings_button);

    main_box.append(&sidebar_frame);
    main_box.append(&gtk4::Separator::new(Orientation::Vertical));
    main_box.append(&detail_box);

    let toolbar_view = adw::ToolbarView::new();
    toolbar_view.add_top_bar(&header);
    toolbar_view.set_content(Some(&main_box));
    window.set_content(Some(&toolbar_view));

    // --- Create shared PINManager ---
    let pin_manager = crate::services::pin_manager::PINManager::new();

    // --- Start background services ---
    start_services(shared_state.clone(), window_backend.clone(), input_backend.clone(), pin_manager.clone());

    // --- Periodic refresh ---
    let wb_timer = window_backend.clone();
    let ss_timer = shared_state.clone();
    let sidebar_refresh = sidebar_widget.clone();
    let preview_refresh = preview.clone();
    let status_refresh = status_bar.clone();
    glib::timeout_add_local(std::time::Duration::from_secs(2), move || {
        {
            let mut state = ss_timer.write().unwrap();
            state.refresh_windows(&*wb_timer);
            state.refresh_subtitles();
            state.state_detector.poll_all();
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

    for (i, window) in enabled.iter().enumerate() {
        if i >= frames.len() {
            break;
        }
        let frame = &frames[i];
        let x = screen.x + (frame.x * screen.width as f64) as i32;
        let y = screen.y + (frame.y * screen.height as f64) as i32;
        let w = (frame.width * screen.width as f64) as u32;
        let h = (frame.height * screen.height as f64) as u32;

        if let Err(e) = backend.move_resize_window(window.window_id, x, y, w, h) {
            tracing::warn!("Failed to arrange window {}: {e}", window.id);
        }
    }

    tracing::info!("Arranged {} windows", enabled.len());
}

fn start_services(
    shared_state: SharedState,
    window_backend: Arc<dyn platform::traits::WindowBackend>,
    input_backend: Arc<dyn platform::traits::InputBackend>,
    pin_manager: crate::services::pin_manager::PINManager,
) {
    let port = {
        let state = shared_state.read().unwrap();
        state.settings.general.websocket_port
    };
    let bonjour_name = {
        let state = shared_state.read().unwrap();
        state.settings.general.bonjour_name.clone()
    };

    // Channel for incoming WS messages -> GTK thread
    let (gtk_tx, gtk_rx) = async_channel::bounded::<String>(256);
    let (msg_tx, msg_rx) = tokio::sync::mpsc::unbounded_channel::<String>();

    // Create WsServer before spawning the background thread so it can be shared
    let ws_server = Arc::new(crate::services::ws_server::WsServer::new(port, msg_tx, pin_manager));

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

            // Start Cloudflare tunnel
            let ss_tunnel = ss_bg.clone();
            tokio::spawn(async move {
                let mut tunnel = crate::services::cloudflare_tunnel::CloudflareTunnel::new();
                {
                    let mut state = ss_tunnel.write().unwrap();
                    state.tunnel_running = true;
                }
                match tunnel.start(port).await {
                    Ok(()) => {
                        tracing::info!("Cloudflare tunnel started: {}", tunnel.ws_url());
                        let mut state = ss_tunnel.write().unwrap();
                        state.tunnel_url = tunnel.public_url().to_string();
                        state.tunnel_ws_url = tunnel.ws_url().to_string();
                    }
                    Err(e) => {
                        tracing::warn!("Cloudflare tunnel failed: {e}");
                        let mut state = ss_tunnel.write().unwrap();
                        state.tunnel_running = false;
                    }
                }
                // Keep tunnel alive
                loop {
                    tokio::time::sleep(std::time::Duration::from_secs(60)).await;
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
    glib::spawn_future_local(async move {
        while let Ok(json) = gtk_rx.recv().await {
            handle_incoming_message(&json, &ss_handler, &*wb_handler, &*ib_handler, &ws_handler);
        }
    });
}

fn handle_incoming_message(
    json: &str,
    shared_state: &SharedState,
    window_backend: &dyn platform::traits::WindowBackend,
    input_backend: &dyn platform::traits::InputBackend,
    ws_server: &crate::services::ws_server::WsServer,
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

    let mut state = shared_state.write().unwrap();

    match action {
        IncomingAction::SelectWindow(window_id) => {
            state.focus_window(&window_id, window_backend);
        }
        IncomingAction::SendText { window_id, text, press_return } => {
            tracing::info!("SendText: window_id={window_id}, text={text}, press_return={press_return}");
            if let Some(w) = state.windows.iter().find(|w| w.id == window_id) {
                let wid = w.window_id;
                tracing::info!("Found window, xdotool target wid={wid}");
                state.focus_window(&window_id, window_backend);
                if let Err(e) = input_backend.send_text(wid, &text, press_return) {
                    tracing::warn!("Failed to send text to {window_id}: {e}");
                } else {
                    tracing::info!("Text sent successfully");
                }
            } else {
                tracing::warn!("Window not found for id: {window_id}");
            }
        }
        IncomingAction::QuickAction { window_id, action } => {
            if let Some(w) = state.windows.iter().find(|w| w.id == window_id) {
                let wid = w.window_id;
                match action.as_str() {
                    "press_return" => { let _ = input_backend.send_keystroke(wid, "return"); }
                    "press_ctrl_c" => { let _ = input_backend.send_keystroke(wid, "ctrl+c"); }
                    "clear_terminal" => { let _ = input_backend.send_text(wid, "/clear", true); }
                    "restart_claude" => {
                        let _ = input_backend.send_keystroke(wid, "ctrl+c");
                        std::thread::sleep(std::time::Duration::from_millis(500));
                        let _ = input_backend.send_text(wid, "claude", true);
                    }
                    "toggle_enabled" => {
                        let enabled = w.is_enabled;
                        state.toggle_window(&window_id, !enabled);
                    }
                    _ => {}
                }
            }
        }
        IncomingAction::SttStarted(window_id) => {
            state.state_detector.set_stt_active(&window_id);
            // Apply terminal color
            if let Some(w) = state.windows.iter().find(|w| w.id == window_id) {
                crate::services::terminal_color::set_background_color(
                    w.pid,
                    &state.settings.colors.stt_active,
                );
            }
        }
        IncomingAction::SttEnded(window_id) => {
            state.state_detector.clear_stt(&window_id);
            if let Some(w) = state.windows.iter().find(|w| w.id == window_id) {
                crate::services::terminal_color::reset_background_color(w.pid);
            }
        }
        IncomingAction::RequestContent(window_id) => {
            let content = if let Some(w) = state.windows.iter().find(|w| w.id == window_id) {
                match input_backend.read_content(w.window_id) {
                    Ok(text) => {
                        // Trim to last ~200 lines
                        let lines: Vec<&str> = text.lines().collect();
                        let start = lines.len().saturating_sub(200);
                        lines[start..].join("\n")
                    }
                    Err(e) => format!("(Failed to read terminal content: {e})"),
                }
            } else {
                "(Window not found)".into()
            };
            let content = crate::services::secret_redactor::redact(&content);
            let msg = crate::protocol::messages::TerminalContentMessage::new(window_id, content);
            if let Some(json) = crate::protocol::messages::encode_message(&msg) {
                ws_server.broadcast(&json);
            }
        }
    }
}
