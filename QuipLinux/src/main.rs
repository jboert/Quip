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

    // Refuse to run as a second daemon for the same user. Two instances
    // racing on port 8765 leaves one with the WS bind and one without — but
    // both have a working GTK UI, so toggling a window in the wrong instance
    // produces "iOS shows No windows while desktop says it's selected". The
    // flock is per-user (XDG_RUNTIME_DIR) and auto-releases on process exit.
    match services::single_instance::acquire_or_report() {
        services::single_instance::AcquireOutcome::Acquired => {}
        services::single_instance::AcquireOutcome::AlreadyHeldBy(pid) => {
            let pid_str = pid.map(|p| p.to_string()).unwrap_or_else(|| "unknown".into());
            eprintln!(
                "Quip is already running (pid {pid_str}). Use the existing window, or `kill {pid_str}` to replace it."
            );
            tracing::error!("single-instance: another quip-linux is running (pid {pid_str}); exiting");
            std::process::exit(1);
        }
    }

    // Detect display server
    let session = platform::detect_session_type();
    tracing::info!("Session type: {:?}", session);

    // Pin GDK to a backend that matches the live session. Otherwise GTK will
    // cheerfully try whatever DISPLAY points at — including a stale X display
    // like :20 left over from a prior session — and fail with "Failed to open
    // display". If we detect a live Wayland socket but GDK_BACKEND is pinned
    // to x11 only, prepend wayland so GTK tries the live socket first.
    let detected_wayland = matches!(session, platform::SessionType::Wayland);
    let current_backend = std::env::var("GDK_BACKEND").ok();
    let backend_has_wayland = current_backend
        .as_deref()
        .map(|v| v.split(&[',', ':'][..]).any(|b| b.trim() == "wayland"))
        .unwrap_or(false);
    if detected_wayland && !backend_has_wayland {
        std::env::set_var("GDK_BACKEND", "wayland,x11");
    } else if current_backend.is_none() && matches!(session, platform::SessionType::X11) {
        std::env::set_var("GDK_BACKEND", "x11");
    }

    // If DBUS_SESSION_BUS_ADDRESS points at a socket that no longer exists
    // (a stale /tmp/dbus-XXXX from a prior login lingering in the shell env
    // is the common case), fall back to /run/user/$UID/bus. Without this,
    // every dbus-send the app shells out to — KWin window enumeration, the
    // portal calls — fails silently and the window list comes up empty.
    if let Some(addr) = std::env::var_os("DBUS_SESSION_BUS_ADDRESS") {
        let addr = addr.to_string_lossy().into_owned();
        let socket = addr
            .split(',')
            .find_map(|part| part.strip_prefix("unix:path="))
            .map(std::path::Path::new);
        let stale = matches!(socket, Some(p) if !p.exists());
        if stale {
            let fallback = std::env::var("XDG_RUNTIME_DIR")
                .ok()
                .map(|rt| format!("{rt}/bus"))
                .filter(|p| std::path::Path::new(p).exists());
            if let Some(fallback) = fallback {
                tracing::warn!("DBUS_SESSION_BUS_ADDRESS={addr:?} is stale; falling back to {fallback}");
                std::env::set_var(
                    "DBUS_SESSION_BUS_ADDRESS",
                    format!("unix:path={fallback}"),
                );
            }
        }
    }

    // Initialize GTK + libadwaita
    let app = adw::Application::builder()
        .application_id("dev.quip.linux")
        .flags(gtk4::gio::ApplicationFlags::empty())
        .build();

    app.connect_activate(move |app| {
        // If a window already exists, just present it (single-instance)
        if let Some(window) = app.active_window() {
            window.present();
            return;
        }
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
