//! Win32 backend: M2+ (listing, displays, focus, typing, arrange, tray).
//!
//! M1 ships the type and a constructor that fails clearly, so the binary
//! builds for `x86_64-pc-windows-gnu` and says what is missing instead of
//! pretending. Nothing here calls Win32 yet, so there is no `unsafe`.

use crate::platform::traits::{
    FocusStep, InputBackend, PlatformDisplay, PlatformError, PlatformResult, PlatformWindow, WindowBackend, WindowMove,
    WindowRef,
};
use crate::services::keys::KeyChord;
use crate::services::multiline_policy::Shell;

pub const NOT_IMPLEMENTED: &str = "the Win32 backend is not implemented in M1 (use --fake-platform)";

pub struct Win32Platform {
    _private: (),
}

impl Win32Platform {
    pub fn new() -> PlatformResult<Self> {
        Err(PlatformError::NotImplemented(NOT_IMPLEMENTED))
    }
}

fn ni<T>() -> PlatformResult<T> {
    Err(PlatformError::NotImplemented(NOT_IMPLEMENTED))
}

impl WindowBackend for Win32Platform {
    fn list_windows(&self) -> PlatformResult<Vec<PlatformWindow>> {
        ni()
    }
    fn list_displays(&self) -> PlatformResult<Vec<PlatformDisplay>> {
        ni()
    }
    fn foreground_window(&self) -> PlatformResult<Option<WindowRef>> {
        ni()
    }
    fn current_shell(&self, _window: WindowRef) -> PlatformResult<Option<Shell>> {
        ni()
    }
    fn bring_to_foreground(&self, _window: WindowRef) -> PlatformResult<FocusStep> {
        ni()
    }
    fn move_windows(&self, moves: &[WindowMove]) -> Vec<PlatformResult<()>> {
        moves.iter().map(|_| ni()).collect()
    }
    fn minimize(&self, _window: WindowRef) -> PlatformResult<()> {
        ni()
    }
    fn close(&self, _window: WindowRef) -> PlatformResult<()> {
        ni()
    }
}

impl InputBackend for Win32Platform {
    fn send_units(&self, _window: WindowRef, _units: &[u16]) -> PlatformResult<usize> {
        ni()
    }
    fn press_key(&self, _window: WindowRef, _chord: KeyChord) -> PlatformResult<usize> {
        ni()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn constructor_says_what_is_missing() {
        assert!(matches!(Win32Platform::new(), Err(PlatformError::NotImplemented(m)) if m.contains("M1")));
    }
}
