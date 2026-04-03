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
        setup_icon();
        ui::build_ui(app);
    });

    app.run();
}

/// Set up the application icon for the dock/taskbar.
fn setup_icon() {
    // Find the icon PNG relative to the binary
    let icon_path = find_icon_path();
    if let Some(path) = &icon_path {
        tracing::info!("Found app icon at {}", path.display());
        // Add the hicolor parent to the icon theme search path
        if let Some(hicolor_root) = path.parent()
            .and_then(|p| p.parent())
            .and_then(|p| p.parent())
            .and_then(|p| p.parent())
        {
            if let Some(display) = gdk4::Display::default() {
                let icon_theme = gtk4::IconTheme::for_display(&display);
                icon_theme.add_search_path(hicolor_root);
            }
        }
    }
    gtk4::Window::set_default_icon_name("quip");
}

fn find_icon_path() -> Option<std::path::PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let exe_dir = exe.parent()?;

    // Possible icon locations relative to the binary
    let candidates = [
        // Dev build: target/release/../Quip.AppDir/...
        exe_dir.join("../Quip.AppDir/usr/share/icons/hicolor/256x256/apps/quip.png"),
        exe_dir.join("../../Quip.AppDir/usr/share/icons/hicolor/256x256/apps/quip.png"),
        // AppImage mount
        exe_dir.join("usr/share/icons/hicolor/256x256/apps/quip.png"),
    ];

    for candidate in &candidates {
        if candidate.exists() {
            return Some(candidate.canonicalize().unwrap_or(candidate.clone()));
        }
    }

    None
}
