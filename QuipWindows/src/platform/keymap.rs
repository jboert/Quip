//! Keys as `SendInput` events (spec 5.5), pure so every mapping is
//! Mac-tested; `win32::input` only turns these into `INPUT` structs.
//!
//! - Virtual keys: `VK_RETURN`, `VK_ESCAPE`, `VK_TAB`, `VK_BACK`, and the
//!   arrows with `KEYEVENTF_EXTENDEDKEY` (without it they are the numeric
//!   keypad's keys). A letter is its uppercase ASCII code (`'C'` = 0x43).
//! - A chord is ONE `SendInput` call: Ctrl, then Shift, down; the key down
//!   and up; the modifiers up in reverse order. Its length is
//!   `KeyChord::input_count()`, which the injector checks against what
//!   Windows reports it inserted.
//! - Text is a `KEYEVENTF_UNICODE` down/up pair per UTF-16 unit (vk 0, scan
//!   = the unit); Windows reassembles surrogate pairs.
//!
//! Mac twins: `GenericAppInjectionTests.testSpecialKeysUseVirtualKeyCodes`,
//! `testModifiedKeysCarryTheirModifier`, and
//! `KeystrokeInjectorWriteExpressionTests.test_keyCodeFor_mappedKeys` /
//! `test_arrowKeys_areCSISequences` (here: the extended flag).

use crate::services::keys::{Key, KeyChord};

pub const VK_BACK: u16 = 0x08;
pub const VK_TAB: u16 = 0x09;
pub const VK_RETURN: u16 = 0x0D;
pub const VK_SHIFT: u16 = 0x10;
pub const VK_CONTROL: u16 = 0x11;
pub const VK_MENU: u16 = 0x12;
pub const VK_ESCAPE: u16 = 0x1B;
pub const VK_UP: u16 = 0x26;
pub const VK_RIGHT: u16 = 0x27;
pub const VK_DOWN: u16 = 0x28;

/// One keyboard `INPUT`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyEvent {
    /// Virtual key; 0 for a unicode event.
    pub vk: u16,
    /// The UTF-16 unit of a unicode event; 0 otherwise.
    pub scan: u16,
    pub up: bool,
    /// `KEYEVENTF_EXTENDEDKEY`.
    pub extended: bool,
    /// `KEYEVENTF_UNICODE`.
    pub unicode: bool,
}

impl KeyEvent {
    const fn vk(vk: u16, up: bool, extended: bool) -> Self {
        KeyEvent { vk, scan: 0, up, extended, unicode: false }
    }
    const fn unit(unit: u16, up: bool) -> Self {
        KeyEvent { vk: 0, scan: unit, up, extended: false, unicode: true }
    }
}

/// The virtual key and its extended flag; `None` for a letter that has no
/// virtual key of its own (not an ASCII letter or digit), which is never
/// pressed as a guess.
pub fn vk(key: Key) -> Option<(u16, bool)> {
    Some(match key {
        Key::Return => (VK_RETURN, false),
        Key::Escape => (VK_ESCAPE, false),
        Key::Tab => (VK_TAB, false),
        Key::Backspace => (VK_BACK, false),
        Key::Up => (VK_UP, true),
        Key::Down => (VK_DOWN, true),
        Key::Right => (VK_RIGHT, true),
        Key::Letter(c) if c.is_ascii_alphanumeric() => (c.to_ascii_uppercase() as u16, false),
        Key::Letter(_) => return None,
    })
}

/// The events of one chord, in order; `None` when its key has no virtual key.
pub fn chord_events(chord: KeyChord) -> Option<Vec<KeyEvent>> {
    let (key, extended) = vk(chord.key)?;
    let mods: Vec<u16> =
        [(chord.ctrl, VK_CONTROL), (chord.shift, VK_SHIFT)].into_iter().filter(|(on, _)| *on).map(|(_, m)| m).collect();
    let mut out: Vec<KeyEvent> = mods.iter().map(|&m| KeyEvent::vk(m, false, false)).collect();
    out.push(KeyEvent::vk(key, false, extended));
    out.push(KeyEvent::vk(key, true, extended));
    out.extend(mods.iter().rev().map(|&m| KeyEvent::vk(m, true, false)));
    Some(out)
}

/// A down/up pair per UTF-16 unit.
pub fn unit_events(units: &[u16]) -> Vec<KeyEvent> {
    units.iter().flat_map(|&u| [KeyEvent::unit(u, false), KeyEvent::unit(u, true)]).collect()
}

/// The Alt tap of spec 5.3 step 4.
pub const ALT_TAP: [KeyEvent; 2] = [KeyEvent::vk(VK_MENU, false, false), KeyEvent::vk(VK_MENU, true, false)];

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::keys::{self, QuickActionPlan};

    fn all_chords() -> Vec<KeyChord> {
        let mut out = vec![KeyChord::SHIFT_ENTER, KeyChord::RETURN];
        for a in keys::SUPPORTED_ACTIONS {
            if let QuickActionPlan::Keys(c) = keys::plan(a) {
                out.extend(c);
            }
        }
        out
    }

    #[test]
    fn every_supported_action_has_virtual_keys() {
        for c in all_chords() {
            let ev = chord_events(c).unwrap_or_else(|| panic!("{c:?} has no virtual key"));
            assert!(ev.iter().all(|e| e.vk != 0 && !e.unicode), "{c:?}");
        }
        let want = [
            ("press_return", VK_RETURN),
            ("press_ctrl_c", 0x43),
            ("press_ctrl_d", 0x44),
            ("press_escape", VK_ESCAPE),
            ("press_tab", VK_TAB),
            ("press_shift_tab", VK_TAB),
            ("press_up", VK_UP),
            ("press_down", VK_DOWN),
            ("press_right", VK_RIGHT),
            ("press_backspace", VK_BACK),
            ("clear_input", VK_ESCAPE),
        ];
        for (action, key) in want {
            let QuickActionPlan::Keys(c) = keys::plan(action) else { panic!("{action}") };
            assert_eq!(vk(c[0].key).map(|(v, _)| v), Some(key), "{action}");
        }
    }

    #[test]
    fn arrows_are_extended_and_return_is_not() {
        for k in [Key::Up, Key::Down, Key::Right] {
            assert_eq!(vk(k).map(|(_, e)| e), Some(true), "{k:?}");
            assert!(chord_events(KeyChord::plain(k)).unwrap().iter().all(|e| e.extended));
        }
        for k in [Key::Return, Key::Escape, Key::Tab, Key::Backspace, Key::Letter('c')] {
            assert_eq!(vk(k).map(|(_, e)| e), Some(false), "{k:?}");
        }
        assert!(chord_events(KeyChord::shift(Key::Up))
            .unwrap()
            .iter()
            .filter(|e| e.vk == VK_SHIFT)
            .all(|e| !e.extended));
    }

    #[test]
    fn a_letter_is_its_uppercase_code_and_others_have_none() {
        assert_eq!(vk(Key::Letter('c')), Some((0x43, false)));
        assert_eq!(vk(Key::Letter('D')), Some((0x44, false)));
        assert_eq!(vk(Key::Letter('7')), Some((0x37, false)));
        assert_eq!(vk(Key::Letter('é')), None);
        assert_eq!(vk(Key::Letter(' ')), None);
        assert_eq!(chord_events(KeyChord::ctrl(Key::Letter('é'))), None);
    }

    #[test]
    fn chords_press_modifiers_first_and_release_them_last() {
        let ev = chord_events(KeyChord { key: Key::Tab, ctrl: true, shift: true }).unwrap();
        let got: Vec<(u16, bool)> = ev.iter().map(|e| (e.vk, e.up)).collect();
        assert_eq!(
            got,
            [
                (VK_CONTROL, false),
                (VK_SHIFT, false),
                (VK_TAB, false),
                (VK_TAB, true),
                (VK_SHIFT, true),
                (VK_CONTROL, true)
            ]
        );
        let got: Vec<(u16, bool)> =
            chord_events(KeyChord::ctrl(Key::Letter('c'))).unwrap().iter().map(|e| (e.vk, e.up)).collect();
        assert_eq!(got, [(VK_CONTROL, false), (0x43, false), (0x43, true), (VK_CONTROL, true)]);
        let got: Vec<(u16, bool)> = chord_events(KeyChord::RETURN).unwrap().iter().map(|e| (e.vk, e.up)).collect();
        assert_eq!(got, [(VK_RETURN, false), (VK_RETURN, true)]);
    }

    #[test]
    fn event_count_matches_input_count() {
        let mut chords = all_chords();
        chords.push(KeyChord { key: Key::Tab, ctrl: true, shift: true });
        for c in chords {
            assert_eq!(chord_events(c).unwrap().len(), c.input_count(), "{c:?}");
        }
    }

    #[test]
    fn unicode_units_are_down_up_pairs() {
        let units: Vec<u16> = "a🙂".encode_utf16().collect();
        let ev = unit_events(&units);
        assert_eq!(ev.len(), 6);
        for (i, e) in ev.iter().enumerate() {
            assert!(e.unicode && e.vk == 0 && !e.extended);
            assert_eq!(e.scan, units[i / 2]);
            assert_eq!(e.up, i % 2 == 1);
        }
        assert!(unit_events(&[]).is_empty());
    }

    #[test]
    fn the_alt_tap_is_a_menu_down_then_up() {
        assert_eq!(ALT_TAP.map(|e| (e.vk, e.up)), [(VK_MENU, false), (VK_MENU, true)]);
    }
}
