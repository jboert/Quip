use gdk4::prelude::*;
use gtk4::prelude::*;
use gtk4::{self, Orientation};
use libadwaita as adw;
use libadwaita::prelude::*;

use crate::models::settings::NetworkMode;
use crate::services::connection_log::ConnectionLog;
use crate::services::pin_manager::PINManager;
use crate::services::push_service::PushService;
use crate::services::whisper_service::WhisperService;
use crate::state::SharedState;
use glib;
use std::sync::Arc;

use super::main_window::RuntimeCommand;

/// Show the settings preferences window
pub fn show_settings(
    parent: &adw::ApplicationWindow,
    shared_state: &SharedState,
    pin_manager: &PINManager,
    runtime_cmd_tx: &async_channel::Sender<RuntimeCommand>,
    whisper: &Arc<WhisperService>,
    push: &Arc<PushService>,
    connection_log: &Arc<ConnectionLog>,
) {
    let prefs = adw::PreferencesWindow::builder()
        .title("Quip Settings")
        .transient_for(parent)
        .modal(true)
        .build();

    // General page
    let general_page = adw::PreferencesPage::builder()
        .title("General")
        .icon_name("emblem-system-symbolic")
        .build();

    let connection_group = adw::PreferencesGroup::builder()
        .title("Connection")
        .build();

    let state = shared_state.read().unwrap();

    // WebSocket port
    let port_row = adw::ActionRow::builder()
        .title("WebSocket Port")
        .subtitle(&format!("{}", state.settings.general.websocket_port))
        .build();
    connection_group.add(&port_row);

    // Bonjour name
    let name_row = adw::ActionRow::builder()
        .title("Service Name")
        .subtitle(&state.settings.general.bonjour_name)
        .build();
    connection_group.add(&name_row);

    general_page.add(&connection_group);

    // Terminal group
    let terminal_group = adw::PreferencesGroup::builder()
        .title("Terminal")
        .build();

    let terminal_row = adw::ActionRow::builder()
        .title("Default Terminal")
        .subtitle(&state.settings.general.default_terminal)
        .build();
    terminal_group.add(&terminal_row);

    // Windows group
    let windows_group = adw::PreferencesGroup::builder()
        .title("Windows")
        .build();

    let show_all_switch = gtk4::Switch::new();
    show_all_switch.set_active(state.settings.general.show_all_windows);
    show_all_switch.set_valign(gtk4::Align::Center);
    let show_all_row = adw::ActionRow::builder()
        .title("Show All Windows")
        .subtitle("Include non-terminal windows for arranging")
        .build();
    show_all_row.add_suffix(&show_all_switch);
    show_all_row.set_activatable_widget(Some(&show_all_switch));
    let ss_switch = shared_state.clone();
    show_all_switch.connect_state_set(move |_, active| {
        let mut state = ss_switch.write().unwrap();
        state.settings.general.show_all_windows = active;
        state.settings.save();
        glib::Propagation::Proceed
    });
    windows_group.add(&show_all_row);

    // Mirror Desktop — broadcast every terminal window dimmed even when
    // disabled, so the phone can tap-to-enable. Mirrors Mac's mirrorDesktop
    // setting.
    let mirror_switch = gtk4::Switch::new();
    mirror_switch.set_active(state.settings.general.mirror_desktop);
    mirror_switch.set_valign(gtk4::Align::Center);
    let mirror_row = adw::ActionRow::builder()
        .title("Mirror Desktop")
        .subtitle("Show every terminal on the phone (dimmed if disabled)")
        .build();
    mirror_row.add_suffix(&mirror_switch);
    mirror_row.set_activatable_widget(Some(&mirror_switch));
    let ss_mirror = shared_state.clone();
    mirror_switch.connect_state_set(move |_, active| {
        let mut state = ss_mirror.write().unwrap();
        state.settings.general.mirror_desktop = active;
        state.settings.save();
        glib::Propagation::Proceed
    });
    windows_group.add(&mirror_row);

    general_page.add(&terminal_group);
    general_page.add(&windows_group);

    // PTT recognizer status — read once on dialog open so the user can see
    // whether whisper.cpp loaded its model. Mirrors Mac's "Whisper recognizer"
    // row on Settings → General.
    let ptt_group = adw::PreferencesGroup::builder().title("Push-to-Talk").build();
    let whisper_state_text = match whisper.current_state() {
        crate::protocol::messages::WhisperState::Preparing => "Preparing…".to_string(),
        crate::protocol::messages::WhisperState::Downloading { progress } => {
            format!("Downloading model ({}%)", (progress * 100.0).round() as i32)
        }
        crate::protocol::messages::WhisperState::Ready => "Ready".to_string(),
        crate::protocol::messages::WhisperState::Failed { message } => format!("Failed: {message}"),
    };
    let whisper_row = adw::ActionRow::builder()
        .title("Whisper Recognizer")
        .subtitle(&whisper_state_text)
        .build();
    ptt_group.add(&whisper_row);
    general_page.add(&ptt_group);

    // Permissions — mirrors the Mac perms group on Settings → General.
    // Reads PermissionProbe live so the user can see what the iOS perms
    // Live Activity is reading without grabbing the phone.
    let perms = crate::services::permission_probe::PermissionProbe::probe();
    let perms_group = adw::PreferencesGroup::builder()
        .title("Permissions")
        .description("What the host can do for the iOS app right now.")
        .build();
    perms_group.add(&adw::ActionRow::builder()
        .title("Input injection")
        .subtitle(if perms.accessibility {
            "Available — ydotool / wtype / xdotool / Konsole D-Bus detected"
        } else {
            "Missing — install ydotool, wtype, or xdotool to enable PTT and quick buttons"
        })
        .build());
    perms_group.add(&adw::ActionRow::builder()
        .title("Screen recording")
        .subtitle(if perms.screen_recording {
            "Available"
        } else {
            "Not available — Wayland portal denied or X11 capture failing"
        })
        .build());
    general_page.add(&perms_group);

    // About — shows the binary's compiled version, mirroring Mac's
    // Settings → General → About → Version row.
    let about_group = adw::PreferencesGroup::builder().title("About").build();
    let version_row = adw::ActionRow::builder()
        .title("Version")
        .subtitle(env!("CARGO_PKG_VERSION"))
        .build();
    about_group.add(&version_row);
    general_page.add(&about_group);

    // Colors page
    let colors_page = adw::PreferencesPage::builder()
        .title("Colors")
        .icon_name("applications-graphics-symbolic")
        .build();

    let colors_group = adw::PreferencesGroup::builder()
        .title("Terminal Background Colors")
        .description("OSC escape sequences are sent to change terminal backgrounds based on state")
        .build();

    let waiting_row = adw::ActionRow::builder()
        .title("Waiting for Input")
        .subtitle(&state.settings.colors.waiting_for_input)
        .build();
    colors_group.add(&waiting_row);

    let stt_row = adw::ActionRow::builder()
        .title("STT Active")
        .subtitle(&state.settings.colors.stt_active)
        .build();
    colors_group.add(&stt_row);

    colors_page.add(&colors_group);

    drop(state);

    // Security page
    let security_page = adw::PreferencesPage::builder()
        .title("Security")
        .icon_name("channel-secure-symbolic")
        .build();

    let pin_group = adw::PreferencesGroup::builder()
        .title("PIN Authentication")
        .description("Clients must enter this PIN to connect")
        .build();

    let pin_entry = gtk4::Entry::new();
    pin_entry.set_text(&pin_manager.pin());
    pin_entry.add_css_class("monospace");
    pin_entry.set_valign(gtk4::Align::Center);
    pin_entry.set_width_chars(12);

    let pin_row = adw::ActionRow::builder()
        .title("Connection PIN")
        .build();
    pin_row.add_suffix(&pin_entry);

    // Save on every edit
    let pin_for_change = pin_manager.clone();
    pin_entry.connect_changed(move |entry| {
        let text = entry.text().to_string();
        if !text.is_empty() {
            pin_for_change.set_pin(&text);
        }
    });

    pin_group.add(&pin_row);

    // Button row: Copy + Regenerate
    let pin_for_copy = pin_manager.clone();
    let copy_btn = gtk4::Button::with_label("Copy PIN");
    copy_btn.add_css_class("flat");
    copy_btn.connect_clicked(move |_| {
        let pin_text = pin_for_copy.pin();
        if let Some(display) = gdk4::Display::default() {
            display.clipboard().set_text(&pin_text);
        }
    });

    let pin_for_regen = pin_manager.clone();
    let entry_for_regen = pin_entry.clone();
    let regen_btn = gtk4::Button::with_label("Regenerate PIN");
    regen_btn.add_css_class("destructive-action");
    regen_btn.connect_clicked(move |_| {
        pin_for_regen.regenerate();
        entry_for_regen.set_text(&pin_for_regen.pin());
    });

    let button_box = gtk4::Box::new(Orientation::Horizontal, 8);
    button_box.set_halign(gtk4::Align::Center);
    button_box.set_margin_top(8);
    button_box.append(&copy_btn);
    button_box.append(&regen_btn);

    pin_group.add(&button_box);
    security_page.add(&pin_group);

    // Network mode group
    let network_group = adw::PreferencesGroup::builder()
        .title("Network Mode")
        .description("Pick how the phone reaches the Mac: Cloudflare tunnel, Tailscale, or local network only")
        .build();

    // Three-way mode picker: linked toggle buttons (GTK equivalent of a segmented picker).
    let initial_mode = {
        let state = shared_state.read().unwrap();
        state.settings.network_mode()
    };

    let mode_row = adw::ActionRow::builder().title("Connection").build();
    let mode_buttons = gtk4::Box::new(Orientation::Horizontal, 0);
    mode_buttons.add_css_class("linked");
    mode_buttons.set_valign(gtk4::Align::Center);

    let cloud_btn = gtk4::ToggleButton::with_label("Cloudflare");
    let tailscale_btn = gtk4::ToggleButton::with_label("Tailscale");
    let local_btn = gtk4::ToggleButton::with_label("Local only");
    cloud_btn.set_group(Some(&tailscale_btn));
    local_btn.set_group(Some(&tailscale_btn));
    match initial_mode {
        NetworkMode::CloudflareTunnel => cloud_btn.set_active(true),
        NetworkMode::Tailscale => tailscale_btn.set_active(true),
        NetworkMode::LocalOnly => local_btn.set_active(true),
    }
    mode_buttons.append(&cloud_btn);
    mode_buttons.append(&tailscale_btn);
    mode_buttons.append(&local_btn);
    mode_row.add_suffix(&mode_buttons);

    let caption_label = gtk4::Label::new(None);
    caption_label.add_css_class("caption");
    caption_label.add_css_class("dim-label");
    caption_label.set_wrap(true);
    caption_label.set_xalign(0.0);
    caption_label.set_margin_start(12);
    caption_label.set_margin_end(12);
    caption_label.set_margin_top(4);
    caption_label.set_margin_bottom(4);
    set_mode_caption(&caption_label, initial_mode);

    // Tailscale sub-section (only meaningful when tailscale mode is selected).
    let tailscale_group = adw::PreferencesGroup::builder()
        .title("Tailscale")
        .build();

    let tailscale_host_row = adw::ActionRow::builder()
        .title("Detected hostname")
        .subtitle("Not detected")
        .build();
    tailscale_group.add(&tailscale_host_row);

    let tailscale_error_row = adw::ActionRow::builder()
        .title("Last error")
        .subtitle("")
        .build();
    tailscale_error_row.set_visible(false);
    tailscale_group.add(&tailscale_error_row);

    let override_entry = gtk4::Entry::new();
    {
        let state = shared_state.read().unwrap();
        override_entry.set_text(&state.settings.general.tailscale_hostname_override);
    }
    override_entry.set_placeholder_text(Some("e.g. quip.tail1234.ts.net"));
    override_entry.set_valign(gtk4::Align::Center);
    override_entry.set_width_chars(24);
    let override_row = adw::ActionRow::builder()
        .title("Hostname override")
        .subtitle("Leave blank to auto-detect via the Tailscale CLI")
        .build();
    override_row.add_suffix(&override_entry);
    tailscale_group.add(&override_row);

    let redetect_btn = gtk4::Button::with_label("Re-detect");
    redetect_btn.add_css_class("flat");
    redetect_btn.set_valign(gtk4::Align::Center);
    let redetect_row = adw::ActionRow::builder()
        .title("Detection")
        .subtitle("Re-run `tailscale status` to pick up hostname changes")
        .build();
    redetect_row.add_suffix(&redetect_btn);
    tailscale_group.add(&redetect_row);

    // Poll the shared state every second while the dialog is open so the
    // Tailscale rows reflect the latest detection result without the user
    // having to close and reopen the settings.
    let ss_poll = shared_state.clone();
    let host_row_poll = tailscale_host_row.clone();
    let err_row_poll = tailscale_error_row.clone();
    let ts_group_poll = tailscale_group.clone();
    let poll_id_slot: std::rc::Rc<std::cell::RefCell<Option<glib::SourceId>>> =
        std::rc::Rc::new(std::cell::RefCell::new(None));
    let poll_id = glib::timeout_add_local(std::time::Duration::from_secs(1), move || {
        let state = ss_poll.read().unwrap();
        let mode = state.settings.network_mode();
        ts_group_poll.set_visible(matches!(mode, NetworkMode::Tailscale));
        if state.tailscale_hostname.is_empty() {
            host_row_poll.set_subtitle("Not detected");
        } else {
            host_row_poll.set_subtitle(&state.tailscale_hostname);
        }
        if state.tailscale_last_error.is_empty() {
            err_row_poll.set_visible(false);
        } else {
            err_row_poll.set_subtitle(&state.tailscale_last_error);
            err_row_poll.set_visible(true);
        }
        glib::ControlFlow::Continue
    });
    *poll_id_slot.borrow_mut() = Some(poll_id);
    // Stop polling when the preferences window closes.
    let slot_for_close = poll_id_slot.clone();
    prefs.connect_close_request(move |_| {
        if let Some(id) = slot_for_close.borrow_mut().take() {
            id.remove();
        }
        glib::Propagation::Proceed
    });

    // Require PIN for local
    let require_pin_switch = gtk4::Switch::new();
    {
        let state = shared_state.read().unwrap();
        require_pin_switch.set_active(state.settings.general.require_pin_for_local);
    }
    require_pin_switch.set_valign(gtk4::Align::Center);
    let require_pin_row = adw::ActionRow::builder()
        .title("Require PIN for local connections")
        .subtitle("Local clients must enter the PIN before connecting")
        .build();
    require_pin_row.add_suffix(&require_pin_switch);
    require_pin_row.set_activatable_widget(Some(&require_pin_switch));

    // Wire up mode picker handlers
    let dispatch_mode = {
        let ss = shared_state.clone();
        let cmd_tx = runtime_cmd_tx.clone();
        let caption = caption_label.clone();
        let ts_group = tailscale_group.clone();
        move |mode: NetworkMode| {
            {
                let mut state = ss.write().unwrap();
                state.settings.set_network_mode(mode);
                state.settings.save();
            }
            set_mode_caption(&caption, mode);
            ts_group.set_visible(matches!(mode, NetworkMode::Tailscale));
            let _ = cmd_tx.try_send(RuntimeCommand::SetNetworkMode(mode));
        }
    };

    let dm = dispatch_mode.clone();
    cloud_btn.connect_toggled(move |b| {
        if b.is_active() {
            dm(NetworkMode::CloudflareTunnel);
        }
    });
    let dm = dispatch_mode.clone();
    tailscale_btn.connect_toggled(move |b| {
        if b.is_active() {
            dm(NetworkMode::Tailscale);
        }
    });
    let dm = dispatch_mode.clone();
    local_btn.connect_toggled(move |b| {
        if b.is_active() {
            dm(NetworkMode::LocalOnly);
        }
    });

    // Hostname override: save on every keystroke and re-run detection.
    let ss_override = shared_state.clone();
    let cmd_tx_override = runtime_cmd_tx.clone();
    override_entry.connect_changed(move |entry| {
        {
            let mut state = ss_override.write().unwrap();
            state.settings.general.tailscale_hostname_override =
                entry.text().to_string();
            state.settings.save();
        }
        let _ = cmd_tx_override.try_send(RuntimeCommand::RefreshTailscale);
    });

    let cmd_tx_redetect = runtime_cmd_tx.clone();
    redetect_btn.connect_clicked(move |_| {
        let _ = cmd_tx_redetect.try_send(RuntimeCommand::RefreshTailscale);
    });

    let ss_pin_local = shared_state.clone();
    let cmd_tx_pin = runtime_cmd_tx.clone();
    require_pin_switch.connect_state_set(move |_, active| {
        {
            let mut state = ss_pin_local.write().unwrap();
            state.settings.general.require_pin_for_local = active;
            state.settings.save();
        }
        let _ = cmd_tx_pin.try_send(RuntimeCommand::ReloadAuth);
        glib::Propagation::Proceed
    });

    network_group.add(&mode_row);
    network_group.add(&caption_label);
    network_group.add(&require_pin_row);
    security_page.add(&network_group);
    // Toggle visibility now based on initial mode.
    tailscale_group.set_visible(matches!(initial_mode, NetworkMode::Tailscale));
    security_page.add(&tailscale_group);

    // Projects page
    let projects_page = adw::PreferencesPage::builder()
        .title("Projects")
        .icon_name("folder-symbolic")
        .build();

    let projects_group = adw::PreferencesGroup::builder()
        .title("Project Directories")
        .description("Directories where Claude sessions can be launched (wrapped in tmux)")
        .build();

    let projects_list = gtk4::ListBox::new();
    projects_list.set_selection_mode(gtk4::SelectionMode::None);
    projects_list.add_css_class("boxed-list");

    // Populate existing directories
    {
        let state = shared_state.read().unwrap();
        for dir in &state.settings.directories.projects {
            let row = build_project_row(dir, &projects_list, shared_state);
            projects_list.append(&row);
        }
    }

    projects_group.add(&projects_list);

    // Add directory button
    let add_dir_btn = gtk4::Button::with_label("Add Directory");
    add_dir_btn.add_css_class("flat");
    let ss_add = shared_state.clone();
    let list_ref = projects_list.clone();
    let prefs_ref: adw::PreferencesWindow = prefs.clone();
    add_dir_btn.connect_clicked(move |_| {
        let dialog = gtk4::FileChooserDialog::new(
            Some("Choose project directory"),
            Some(&prefs_ref),
            gtk4::FileChooserAction::SelectFolder,
            &[("Cancel", gtk4::ResponseType::Cancel), ("Select", gtk4::ResponseType::Accept)],
        );
        let ss_cb = ss_add.clone();
        let list_cb = list_ref.clone();
        dialog.connect_response(move |dlg, response| {
            if response == gtk4::ResponseType::Accept {
                if let Some(file) = dlg.file() {
                    if let Some(path) = file.path() {
                        let dir = path.to_string_lossy().to_string();
                        {
                            let mut state = ss_cb.write().unwrap();
                            if !state.settings.directories.projects.contains(&dir) {
                                state.settings.directories.projects.push(dir.clone());
                                state.settings.save();
                            }
                        }
                        let row = build_project_row(&dir, &list_cb, &ss_cb);
                        list_cb.append(&row);
                    }
                }
            }
            dlg.close();
        });
        dialog.show();
    });

    let add_box = gtk4::Box::new(Orientation::Horizontal, 0);
    add_box.set_halign(gtk4::Align::Center);
    add_box.set_margin_top(8);
    add_box.append(&add_dir_btn);
    projects_group.add(&add_box);

    projects_page.add(&projects_group);

    // Notifications page — APNs configuration so the phone gets buzzed when
    // Claude transitions to waiting. Mirrors Mac's Notifications tab.
    let notifications_page = build_notifications_page(push, parent);

    // Diagnostics page — every URL the phone could try, plus a recent
    // connection log so the user can debug "phone says it can't reach me".
    let diagnostics_page = build_diagnostics_page(shared_state, connection_log);

    prefs.add(&general_page);
    prefs.add(&projects_page);
    prefs.add(&colors_page);
    prefs.add(&security_page);
    prefs.add(&notifications_page);
    prefs.add(&diagnostics_page);
    prefs.present();
}

/// Build the Diagnostics page: every URL the phone could try (LAN IPs,
/// Cloudflare tunnel, Tailscale) with a one-tap copy button, plus the
/// recent connection log. Mirrors Mac commit a108ef2.
fn build_diagnostics_page(
    shared_state: &SharedState,
    connection_log: &Arc<ConnectionLog>,
) -> adw::PreferencesPage {
    let page = adw::PreferencesPage::builder()
        .title("Diagnostics")
        .icon_name("dialog-information-symbolic")
        .build();

    // -- URLs --
    let urls_group = adw::PreferencesGroup::builder()
        .title("Connection URLs")
        .description("Every URL the phone might be able to reach this daemon at.")
        .build();

    let mut urls: Vec<(String, String)> = Vec::new();
    {
        let state = shared_state.read().unwrap();
        let port = state.settings.general.websocket_port;
        // LAN — every non-loopback IPv4 we can see.
        if let Ok(ifaces) = if_addrs::get_if_addrs() {
            for iface in ifaces {
                if iface.is_loopback() {
                    continue;
                }
                let ip = iface.addr.ip();
                if ip.is_ipv4() {
                    urls.push((
                        format!("LAN ({})", iface.name),
                        format!("ws://{ip}:{port}"),
                    ));
                }
            }
        }
        if !state.tunnel_ws_url.is_empty() {
            urls.push(("Cloudflare".into(), state.tunnel_ws_url.clone()));
        }
        if !state.tailscale_ws_url.is_empty() {
            urls.push(("Tailscale".into(), state.tailscale_ws_url.clone()));
        }
    }

    if urls.is_empty() {
        urls_group.add(
            &adw::ActionRow::builder()
                .title("(none)")
                .subtitle("Network mode not yet started.")
                .build(),
        );
    } else {
        for (label, url) in urls {
            let row = adw::ActionRow::builder().title(&label).subtitle(&url).build();
            let copy_btn = gtk4::Button::from_icon_name("edit-copy-symbolic");
            copy_btn.add_css_class("flat");
            copy_btn.set_valign(gtk4::Align::Center);
            let url_for_click = url.clone();
            copy_btn.connect_clicked(move |_| {
                if let Some(display) = gdk4::Display::default() {
                    display.clipboard().set_text(&url_for_click);
                }
            });
            row.add_suffix(&copy_btn);
            urls_group.add(&row);
        }
    }
    page.add(&urls_group);

    // -- Recent connection log --
    let log_group = adw::PreferencesGroup::builder()
        .title("Recent Connections")
        .description("Last 20 events. Helps debug why the phone says it can't connect.")
        .build();

    let events = connection_log.snapshot();
    if events.is_empty() {
        log_group.add(
            &adw::ActionRow::builder()
                .title("(none yet)")
                .subtitle("Phone connections will appear here.")
                .build(),
        );
    } else {
        for ev in events {
            // SystemTime → "HH:MM:SS" via duration since UNIX epoch is
            // good enough for diagnostics; chrono would be overkill.
            let secs = ev
                .timestamp
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let h = (secs / 3600) % 24;
            let m = (secs / 60) % 60;
            let s = secs % 60;
            let stamp = format!("{h:02}:{m:02}:{s:02} UTC");
            let kind = ev.kind.as_str();
            let detail = ev.detail.as_deref().unwrap_or("");
            let subtitle = if detail.is_empty() {
                format!("{stamp} • {kind}")
            } else {
                format!("{stamp} • {kind} • {detail}")
            };
            log_group.add(
                &adw::ActionRow::builder()
                    .title(&ev.remote)
                    .subtitle(&subtitle)
                    .build(),
            );
        }
    }
    page.add(&log_group);

    page
}

/// Build the Notifications preferences page: APNs key file picker, the
/// three identifiers (key id, team id, bundle id), an Apply button that
/// installs an `ApnsClient` onto the push service, a Test Push button,
/// and a list of registered iOS devices.
fn build_notifications_page(
    push: &Arc<PushService>,
    parent: &adw::ApplicationWindow,
) -> adw::PreferencesPage {
    let page = adw::PreferencesPage::builder()
        .title("Notifications")
        .icon_name("preferences-system-notifications-symbolic")
        .build();

    // -- APNs key + identifiers --
    let apns_group = adw::PreferencesGroup::builder()
        .title("APNs")
        .description("Apple Push key and identifiers from Apple Developer. The .p8 file is stored in ~/.config/quip with mode 0600.")
        .build();

    let key_status_row = adw::ActionRow::builder()
        .title("Auth Key (.p8)")
        .subtitle(if crate::services::apns_key_store::ApnsKeyStore::has_key() {
            "Stored"
        } else {
            "Not configured"
        })
        .build();

    let upload_btn = gtk4::Button::with_label("Upload .p8");
    upload_btn.add_css_class("flat");
    upload_btn.set_valign(gtk4::Align::Center);
    {
        let parent_ref = parent.clone();
        let row_ref = key_status_row.clone();
        upload_btn.connect_clicked(move |_| {
            let chooser = gtk4::FileChooserNative::new(
                Some("Select Apple .p8 Key"),
                Some(&parent_ref),
                gtk4::FileChooserAction::Open,
                Some("Open"),
                Some("Cancel"),
            );
            let row_for_response = row_ref.clone();
            chooser.connect_response(move |c, resp| {
                if resp == gtk4::ResponseType::Accept {
                    if let Some(file) = c.file().and_then(|f| f.path()) {
                        match std::fs::read(&file) {
                            Ok(bytes) => {
                                match crate::services::apns_key_store::ApnsKeyStore::set(&bytes) {
                                    Ok(()) => row_for_response.set_subtitle("Stored"),
                                    Err(e) => row_for_response
                                        .set_subtitle(&format!("Save failed: {e}")),
                                }
                            }
                            Err(e) => row_for_response.set_subtitle(&format!("Read failed: {e}")),
                        }
                    }
                }
            });
            chooser.show();
        });
    }
    key_status_row.add_suffix(&upload_btn);
    apns_group.add(&key_status_row);

    let key_id_entry = gtk4::Entry::new();
    key_id_entry.set_placeholder_text(Some("ABC1234DEF"));
    key_id_entry.set_valign(gtk4::Align::Center);
    let key_id_row = adw::ActionRow::builder().title("Key ID").build();
    key_id_row.add_suffix(&key_id_entry);
    apns_group.add(&key_id_row);

    let team_id_entry = gtk4::Entry::new();
    team_id_entry.set_placeholder_text(Some("TEAMID12AB"));
    team_id_entry.set_valign(gtk4::Align::Center);
    let team_id_row = adw::ActionRow::builder().title("Team ID").build();
    team_id_row.add_suffix(&team_id_entry);
    apns_group.add(&team_id_row);

    let bundle_id_entry = gtk4::Entry::new();
    bundle_id_entry.set_placeholder_text(Some("com.example.app"));
    bundle_id_entry.set_valign(gtk4::Align::Center);
    let bundle_id_row = adw::ActionRow::builder().title("Bundle ID").build();
    bundle_id_row.add_suffix(&bundle_id_entry);
    apns_group.add(&bundle_id_row);

    let status_label = gtk4::Label::new(Some(""));
    status_label.add_css_class("caption");
    status_label.add_css_class("dim-label");
    status_label.set_xalign(0.0);
    status_label.set_margin_start(12);
    status_label.set_margin_end(12);

    let apply_btn = gtk4::Button::with_label("Apply");
    apply_btn.add_css_class("suggested-action");

    let test_btn = gtk4::Button::with_label("Send Test Push");
    test_btn.add_css_class("flat");
    test_btn.set_sensitive(false);

    {
        let push = Arc::clone(push);
        let key_id = key_id_entry.clone();
        let team_id = team_id_entry.clone();
        let bundle_id = bundle_id_entry.clone();
        let status = status_label.clone();
        let test = test_btn.clone();
        apply_btn.connect_clicked(move |_| {
            let kid = key_id.text().trim().to_string();
            let tid = team_id.text().trim().to_string();
            let bid = bundle_id.text().trim().to_string();
            if kid.is_empty() || tid.is_empty() || bid.is_empty() {
                status.set_text("Fill in all three identifiers before applying.");
                return;
            }
            match crate::services::apns_client::ApnsClient::new(kid, tid, bid) {
                Ok(client) => {
                    push.set_apns_client(client);
                    status.set_text("APNs client configured. Push test or wait for next claude-waiting transition.");
                    test.set_sensitive(true);
                }
                Err(e) => {
                    status.set_text(&format!("Apply failed: {e}"));
                    test.set_sensitive(false);
                }
            }
        });
    }

    {
        let push = Arc::clone(push);
        let status = status_label.clone();
        test_btn.connect_clicked(move |_| {
            let n =
                push.send_for_window_state("test-window", "Quip", "Test push from Linux");
            status.set_text(&format!(
                "Sent to {n} device(s). If 0, no devices registered yet — connect the iPhone first.",
            ));
        });
    }

    let buttons = gtk4::Box::new(Orientation::Horizontal, 8);
    buttons.set_halign(gtk4::Align::Center);
    buttons.set_margin_top(8);
    buttons.append(&apply_btn);
    buttons.append(&test_btn);
    apns_group.add(&buttons);
    apns_group.add(&status_label);

    page.add(&apns_group);

    // -- Registered devices --
    let devices_group = adw::PreferencesGroup::builder()
        .title("Registered Devices")
        .description("iOS devices currently registered to receive pushes from this Quip Linux daemon.")
        .build();

    let devices = push.devices();
    if devices.is_empty() {
        let empty_row = adw::ActionRow::builder()
            .title("(none)")
            .subtitle("Open the Quip iOS app and authenticate to register a device.")
            .build();
        devices_group.add(&empty_row);
    } else {
        for d in &devices {
            // Show first 12 chars of token + environment.
            let short = d.token.chars().take(12).collect::<String>();
            let row = adw::ActionRow::builder()
                .title(&format!("{short}…"))
                .subtitle(&format!("environment: {}", d.environment))
                .build();
            devices_group.add(&row);
        }
    }
    page.add(&devices_group);

    page
}

fn set_mode_caption(label: &gtk4::Label, mode: NetworkMode) {
    let text = match mode {
        NetworkMode::CloudflareTunnel => {
            "Cloudflare tunnel enables connections from anywhere. Local connections always require PIN when tunnel is active."
        }
        NetworkMode::Tailscale => {
            "Both devices must be on your Tailscale network. The URL stays stable across restarts."
        }
        NetworkMode::LocalOnly => {
            "Clients must be on the same network. QR code shows the local address."
        }
    };
    label.set_text(text);
}

fn build_project_row(dir: &str, list: &gtk4::ListBox, shared_state: &SharedState) -> adw::ActionRow {
    let dir_name = std::path::Path::new(dir)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(dir);

    let row = adw::ActionRow::builder()
        .title(dir_name)
        .subtitle(dir)
        .build();

    let remove_btn = gtk4::Button::from_icon_name("user-trash-symbolic");
    remove_btn.add_css_class("flat");
    remove_btn.set_valign(gtk4::Align::Center);

    let dir_owned = dir.to_string();
    let ss_rm = shared_state.clone();
    let list_rm = list.clone();
    let row_ref = row.clone();
    remove_btn.connect_clicked(move |_| {
        {
            let mut state = ss_rm.write().unwrap();
            state.settings.directories.projects.retain(|d| d != &dir_owned);
            state.settings.save();
        }
        list_rm.remove(&row_ref);
    });

    row.add_suffix(&remove_btn);
    row
}
