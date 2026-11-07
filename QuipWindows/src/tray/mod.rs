//! The Windows app shell (spec 6): tray menu, single instance, "Start with
//! Windows", the tray icon and the console attach for the printing commands.
//!
//! `menu`, `icon` and the value rules in `autostart` / `instance` are pure
//! and tested on the Mac; the Win32 halves are tested by
//! `tests/win32_tray.rs` (`QUIP_WIN_UI=1`).

pub mod autostart;
#[cfg(windows)]
pub mod console;
pub mod icon;
pub mod instance;
pub mod menu;
#[cfg(windows)]
pub mod win32;
