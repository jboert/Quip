pub mod display;
pub mod traits;
pub mod x11;
pub mod wayland;

use traits::{WindowBackend, InputBackend};

/// Detected display server session type
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionType {
    X11,
    Wayland,
    Unknown,
}

/// Detect the current display server session type at runtime
pub fn detect_session_type() -> SessionType {
    if std::env::var("WAYLAND_DISPLAY").is_ok() {
        SessionType::Wayland
    } else if std::env::var("DISPLAY").is_ok() {
        SessionType::X11
    } else {
        SessionType::Unknown
    }
}

/// Create the appropriate backends for the current session type
pub fn create_backends() -> (Box<dyn WindowBackend>, Box<dyn InputBackend>, SessionType) {
    let session = detect_session_type();
    match session {
        SessionType::X11 => {
            tracing::info!("Detected X11 session");
            (
                Box::new(x11::X11WindowBackend::new()),
                Box::new(x11::X11InputBackend::new()),
                session,
            )
        }
        SessionType::Wayland => {
            tracing::info!("Detected Wayland session");
            (
                Box::new(wayland::WaylandWindowBackend::new()),
                Box::new(wayland::WaylandInputBackend::new()),
                session,
            )
        }
        SessionType::Unknown => {
            tracing::warn!("No display server detected, falling back to X11");
            (
                Box::new(x11::X11WindowBackend::new()),
                Box::new(x11::X11InputBackend::new()),
                session,
            )
        }
    }
}
