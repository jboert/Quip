mod models;
mod platform;
mod protocol;
mod services;
mod state;
mod ui;

use gtk4::prelude::*;
use libadwaita as adw;

fn main() {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    tracing::info!("Quip Linux starting");

    // Detect display server
    let session = platform::detect_session_type();
    tracing::info!("Session type: {:?}", session);

    // Initialize GTK + libadwaita
    let app = adw::Application::builder()
        .application_id("dev.quip.linux")
        .build();

    app.connect_activate(move |app| {
        ui::build_ui(app);
    });

    app.run();
}
