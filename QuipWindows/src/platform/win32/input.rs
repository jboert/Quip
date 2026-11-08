//! Spec 5.4 step 3 and 5.5: `SendInput`. The events come from the pure
//! `platform::keymap`; this only builds `INPUT` structs and makes the call.
//!
//! `SendInput` types into whatever window is in front. The injector checks,
//! before every call, that this is the target (handle and pid) and that its
//! integrity level allows input (`integrity`); nothing here decides that.
//! A virtual-key event also carries its scan code (`MapVirtualKeyW`), as a
//! real keyboard's does.

use windows::Win32::UI::Input::KeyboardAndMouse::{
    MapVirtualKeyW, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_EXTENDEDKEY,
    KEYEVENTF_KEYUP, KEYEVENTF_UNICODE, MAPVK_VK_TO_VSC, VIRTUAL_KEY,
};

use crate::platform::keymap::{self, KeyEvent};
use crate::platform::traits::{PlatformError, PlatformResult};
use crate::services::keys::KeyChord;

fn to_input(e: KeyEvent) -> INPUT {
    let mut flags = KEYBD_EVENT_FLAGS(0);
    if e.unicode {
        flags |= KEYEVENTF_UNICODE;
    }
    if e.up {
        flags |= KEYEVENTF_KEYUP;
    }
    if e.extended {
        flags |= KEYEVENTF_EXTENDEDKEY;
    }
    let scan = if e.unicode {
        e.scan
    } else {
        // SAFETY: plain value arguments; 0 when there is no scan code.
        u16::try_from(unsafe { MapVirtualKeyW(u32::from(e.vk), MAPVK_VK_TO_VSC) }).unwrap_or(0)
    };
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT { wVk: VIRTUAL_KEY(e.vk), wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 },
        },
    }
}

/// ONE `SendInput` call; how many events Windows inserted.
pub fn send_events(events: &[KeyEvent]) -> usize {
    if events.is_empty() {
        return 0;
    }
    let inputs: Vec<INPUT> = events.iter().copied().map(to_input).collect();
    // SAFETY: `inputs` is a slice of fully initialised keyboard INPUTs and
    // the size passed is that of one INPUT, as the call requires.
    let n = unsafe { SendInput(&inputs, size_of::<INPUT>() as i32) };
    n as usize
}

/// Units fully inserted (a down/up pair each).
pub fn send_units(units: &[u16]) -> usize {
    send_events(&keymap::unit_events(units)) / 2
}

/// Events inserted for the chord. When Windows inserted only part of it,
/// the keys that part pressed are released again (`keymap::releases_after`),
/// so Ctrl or Shift is never left down; the count is still the short one,
/// and the injector stops (`InputBlocked`).
pub fn press_key(chord: KeyChord) -> PlatformResult<usize> {
    let events = keymap::chord_events(chord)
        .ok_or_else(|| PlatformError::Failed(format!("no virtual key for {}", chord.describe())))?;
    let n = send_events(&events);
    if n < events.len() {
        send_events(&keymap::releases_after(&events, n));
    }
    Ok(n)
}
