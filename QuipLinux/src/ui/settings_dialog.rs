use gdk4::prelude::*;
use gtk4::prelude::*;
use gtk4::{self, Orientation};
use libadwaita as adw;
use libadwaita::prelude::*;

use crate::services::pin_manager::PINManager;
use crate::state::SharedState;
use glib;

/// Show the settings preferences window
pub fn show_settings(parent: &adw::ApplicationWindow, shared_state: &SharedState, pin_manager: &PINManager) {
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

    general_page.add(&terminal_group);
    general_page.add(&windows_group);

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

    prefs.add(&general_page);
    prefs.add(&colors_page);
    prefs.add(&security_page);
    prefs.present();
}
