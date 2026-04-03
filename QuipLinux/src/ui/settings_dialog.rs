use gtk4::prelude::*;
use gtk4::{self, Orientation};
use libadwaita as adw;
use libadwaita::prelude::*;

use crate::state::SharedState;

/// Show the settings preferences window
pub fn show_settings(parent: &adw::ApplicationWindow, shared_state: &SharedState) {
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

    general_page.add(&terminal_group);

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

    prefs.add(&general_page);
    prefs.add(&colors_page);
    prefs.present();
}
