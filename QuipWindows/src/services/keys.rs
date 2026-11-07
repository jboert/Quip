//! `quick_action` -> keys (spec 5.5).
//!
//! Action names are the Mac's (`handleQuickAction` in
//! `QuipMac/QuipMacApp.swift`). What they press differs where the Mac's keys
//! are readline / Claude-specific: `clear_input` is Ctrl+U on the Mac and Esc
//! here (PSReadLine clears the line on Esc); `clear_terminal` types `/clear`
//! on the Mac (a Claude command) and `cls` here. Actions the Mac has that the
//! spec does not list (`press_left`, `press_space`, `select_N`, `set_*_mode`,
//! `scroll_*`, `restart_claude`, …) answer "Not supported on Windows yet".

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Key {
    Return,
    Escape,
    Tab,
    Up,
    Down,
    Right,
    Backspace,
    /// A letter pressed with modifiers (Ctrl+C).
    Letter(char),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct KeyChord {
    pub key: Key,
    pub ctrl: bool,
    pub shift: bool,
}

impl KeyChord {
    pub const fn plain(key: Key) -> Self {
        Self { key, ctrl: false, shift: false }
    }
    pub const fn ctrl(key: Key) -> Self {
        Self { key, ctrl: true, shift: false }
    }
    pub const fn shift(key: Key) -> Self {
        Self { key, ctrl: false, shift: true }
    }

    /// The inner-line break PSReadLine treats as AddLine (M0).
    pub const SHIFT_ENTER: KeyChord = KeyChord::shift(Key::Return);
    pub const RETURN: KeyChord = KeyChord::plain(Key::Return);

    /// `SendInput` events for this chord: a down and an up for the key and
    /// for each modifier. A backend reporting fewer was blocked.
    pub const fn input_count(&self) -> usize {
        2 * (1 + self.ctrl as usize + self.shift as usize)
    }

    /// A short, space-free description for log `detail` fields.
    pub fn describe(&self) -> String {
        let mut s = String::new();
        if self.ctrl {
            s.push_str("ctrl+");
        }
        if self.shift {
            s.push_str("shift+");
        }
        match self.key {
            Key::Return => s.push_str("return"),
            Key::Escape => s.push_str("escape"),
            Key::Tab => s.push_str("tab"),
            Key::Up => s.push_str("up"),
            Key::Down => s.push_str("down"),
            Key::Right => s.push_str("right"),
            Key::Backspace => s.push_str("backspace"),
            Key::Letter(c) => s.push(c),
        }
        s
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QuickActionPlan {
    /// Foreground, then press these.
    Keys(Vec<KeyChord>),
    /// Foreground, then type this text (no Return).
    Type(String),
    /// Foreground, type this text, then Return.
    TypeThenReturn(String),
    /// No keys: flip the window's `enabled` (spec 3.3).
    ToggleEnabled,
    /// `error` "Not supported on Windows yet".
    Unsupported,
}

pub const UNSUPPORTED_REASON: &str = "Not supported on Windows yet";

pub fn plan(action: &str) -> QuickActionPlan {
    use QuickActionPlan::*;
    let k = |c: KeyChord| Keys(vec![c]);
    match action {
        "press_return" => k(KeyChord::plain(Key::Return)),
        "press_ctrl_c" => k(KeyChord::ctrl(Key::Letter('c'))),
        "press_ctrl_d" => k(KeyChord::ctrl(Key::Letter('d'))),
        "press_escape" => k(KeyChord::plain(Key::Escape)),
        "press_tab" => k(KeyChord::plain(Key::Tab)),
        "press_shift_tab" => k(KeyChord::shift(Key::Tab)),
        "press_up" => k(KeyChord::plain(Key::Up)),
        "press_down" => k(KeyChord::plain(Key::Down)),
        "press_right" => k(KeyChord::plain(Key::Right)),
        "press_backspace" => k(KeyChord::plain(Key::Backspace)),
        "press_y" => Type("y".into()),
        "press_n" => Type("n".into()),
        "clear_input" => k(KeyChord::plain(Key::Escape)),
        "clear_terminal" => TypeThenReturn("cls".into()),
        "toggle_enabled" => ToggleEnabled,
        _ => Unsupported,
    }
}

/// Every action spec 5.5 maps.
pub const SUPPORTED_ACTIONS: &[&str] = &[
    "press_return",
    "press_ctrl_c",
    "press_ctrl_d",
    "press_escape",
    "press_tab",
    "press_shift_tab",
    "press_up",
    "press_down",
    "press_right",
    "press_backspace",
    "press_y",
    "press_n",
    "clear_input",
    "clear_terminal",
    "toggle_enabled",
];

#[cfg(test)]
mod tests {
    use super::*;
    use QuickActionPlan::*;

    #[test]
    fn spec_5_5_table() {
        let one = |c| Keys(vec![c]);
        let cases = [
            ("press_return", one(KeyChord::plain(Key::Return))),
            ("press_ctrl_c", one(KeyChord::ctrl(Key::Letter('c')))),
            ("press_ctrl_d", one(KeyChord::ctrl(Key::Letter('d')))),
            ("press_escape", one(KeyChord::plain(Key::Escape))),
            ("press_tab", one(KeyChord::plain(Key::Tab))),
            ("press_shift_tab", one(KeyChord::shift(Key::Tab))),
            ("press_up", one(KeyChord::plain(Key::Up))),
            ("press_down", one(KeyChord::plain(Key::Down))),
            ("press_right", one(KeyChord::plain(Key::Right))),
            ("press_backspace", one(KeyChord::plain(Key::Backspace))),
            ("press_y", Type("y".into())),
            ("press_n", Type("n".into())),
            ("clear_input", one(KeyChord::plain(Key::Escape))),
            ("clear_terminal", TypeThenReturn("cls".into())),
            ("toggle_enabled", ToggleEnabled),
        ];
        assert_eq!(cases.len(), SUPPORTED_ACTIONS.len());
        for (action, want) in cases {
            assert_eq!(plan(action), want, "{action}");
        }
    }

    #[test]
    fn every_supported_action_maps() {
        for a in SUPPORTED_ACTIONS {
            assert_ne!(plan(a), Unsupported, "{a}");
        }
    }

    #[test]
    fn unknown_and_mac_only_actions_are_unsupported() {
        for a in [
            "",
            "press_left",
            "press_space",
            "select_1",
            "set_plan_mode",
            "scroll_page_up",
            "restart_claude",
            "PRESS_RETURN",
            "press_return ",
        ] {
            assert_eq!(plan(a), Unsupported, "{a:?}");
        }
    }

    #[test]
    fn input_count_is_a_down_and_up_per_key_and_modifier() {
        assert_eq!(KeyChord::RETURN.input_count(), 2);
        assert_eq!(KeyChord::SHIFT_ENTER.input_count(), 4);
        assert_eq!(KeyChord::ctrl(Key::Letter('c')).input_count(), 4);
        assert_eq!(KeyChord { key: Key::Tab, ctrl: true, shift: true }.input_count(), 6);
    }

    #[test]
    fn describe_is_space_free() {
        assert_eq!(KeyChord::ctrl(Key::Letter('c')).describe(), "ctrl+c");
        assert_eq!(KeyChord::SHIFT_ENTER.describe(), "shift+return");
        assert_eq!(KeyChord::plain(Key::Backspace).describe(), "backspace");
        for k in [Key::Return, Key::Escape, Key::Tab, Key::Up, Key::Down, Key::Right] {
            assert!(!KeyChord::plain(k).describe().contains(' '));
        }
    }
}
