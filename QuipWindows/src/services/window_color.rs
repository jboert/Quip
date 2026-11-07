//! Window colors (`Shared/WindowColor.swift` + `WindowManager.assignColor`).
//!
//! A new window gets the first palette color no tracked window holds, or, once
//! all ten are taken, the next one in rotation. The color then stays with the
//! window id for its life (spec 3.4: "stable per window id").

use std::collections::{HashMap, HashSet};

pub const PALETTE: [&str; 10] =
    ["#F5A623", "#4A90D9", "#7ED321", "#D0021B", "#9013FE", "#50E3C2", "#BD10E0", "#B8E986", "#F8E71C", "#FF6B6B"];

/// `WindowColor.normalized`: `#RRGGBB` upper case, `#` optional, whitespace
/// trimmed; `None` unless exactly six hex digits.
pub fn normalized(raw: &str) -> Option<String> {
    let t = raw.trim();
    let digits = t.strip_prefix('#').unwrap_or(t);
    if digits.len() != 6 || !digits.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    Some(format!("#{}", digits.to_ascii_uppercase()))
}

/// `WindowColor.hex`: components clamped to 0..1, NaN as 0, rounded.
pub fn hex(red: f64, green: f64, blue: f64) -> String {
    fn byte(v: f64) -> u8 {
        if !v.is_finite() {
            return 0;
        }
        (v.clamp(0.0, 1.0) * 255.0).round() as u8
    }
    format!("#{:02X}{:02X}{:02X}", byte(red), byte(green), byte(blue))
}

/// `WindowManager.firstUnusedPaletteColor`.
pub fn first_unused(used: &HashSet<String>) -> Option<&'static str> {
    PALETTE.iter().copied().find(|c| !used.contains(*c))
}

/// `WindowManager.colorsToAvoid`: every color on screen while some palette
/// color is still free; once all ten are taken, only the colors of the windows
/// the phone shows (they are the ones that must stay distinct).
pub fn colors_to_avoid(all: &HashSet<String>, shown: &HashSet<String>) -> HashSet<String> {
    if first_unused(all).is_some() {
        all.clone()
    } else {
        shown.clone()
    }
}

/// Per-id color memory.
#[derive(Debug, Default)]
pub struct ColorAssigner {
    by_id: HashMap<String, String>,
    rotation: usize,
}

impl ColorAssigner {
    /// The color for `id`, assigning one if new. `live_ids` are the windows
    /// tracked right now; colors of windows no longer tracked are freed.
    pub fn color_for(&mut self, id: &str) -> String {
        if let Some(c) = self.by_id.get(id) {
            return c.clone();
        }
        let used: HashSet<String> = self.by_id.values().cloned().collect();
        let c = match first_unused(&used) {
            Some(c) => c.to_string(),
            None => {
                let c = PALETTE[self.rotation % PALETTE.len()].to_string();
                self.rotation += 1;
                c
            }
        };
        self.by_id.insert(id.to_string(), c.clone());
        c
    }

    /// Forget ids that are gone so their colors are offered again.
    pub fn retain(&mut self, live: &HashSet<String>) {
        self.by_id.retain(|id, _| live.contains(id));
    }
}

#[cfg(test)]
mod tests {
    //! `Shared/Tests/WindowColorTests.swift` plus the assignment rule.
    #![allow(non_snake_case)]
    use super::*;

    #[test]
    fn testNormalizedAcceptsHexWithOrWithoutHashAndUppercases() {
        assert_eq!(normalized("#4a90d9").as_deref(), Some("#4A90D9"));
        assert_eq!(normalized("  4A90D9\n").as_deref(), Some("#4A90D9"));
    }

    #[test]
    fn testNormalizedRejectsAnythingButSixHexDigits() {
        for bad in ["", "#", "#FFF", "#FFFFFFF", "#GG0000", "red", "#12 456", "##123456"] {
            assert_eq!(normalized(bad), None, "{bad}");
        }
    }

    #[test]
    fn testHexRoundsAndClampsComponents() {
        assert_eq!(hex(1.0, 0.0, 0.5), "#FF0080");
        assert_eq!(hex(1.2, -0.1, f64::NAN), "#FF0000");
    }

    #[test]
    fn testEveryPaletteColorIsAlreadyNormalized() {
        for c in PALETTE {
            assert_eq!(normalized(c).as_deref(), Some(c));
        }
    }

    #[test]
    fn colors_to_avoid_switches_to_shown_when_the_palette_is_full() {
        let all: HashSet<String> = PALETTE.iter().map(|s| s.to_string()).collect();
        let shown: HashSet<String> = ["#F5A623".to_string()].into_iter().collect();
        assert_eq!(colors_to_avoid(&all, &shown), shown);
        let some: HashSet<String> = ["#F5A623".to_string(), "#123456".to_string()].into_iter().collect();
        assert_eq!(colors_to_avoid(&some, &shown), some);
    }

    #[test]
    fn new_windows_take_palette_colors_in_order() {
        let mut a = ColorAssigner::default();
        assert_eq!(a.color_for("w1"), PALETTE[0]);
        assert_eq!(a.color_for("w2"), PALETTE[1]);
        assert_eq!(a.color_for("w1"), PALETTE[0], "stable per id");
    }

    #[test]
    fn a_freed_color_is_reused_first() {
        let mut a = ColorAssigner::default();
        a.color_for("w1");
        a.color_for("w2");
        a.retain(&["w2".to_string()].into_iter().collect());
        assert_eq!(a.color_for("w3"), PALETTE[0]);
    }

    #[test]
    fn past_ten_windows_colors_rotate() {
        let mut a = ColorAssigner::default();
        for (i, want) in PALETTE.iter().enumerate() {
            assert_eq!(a.color_for(&format!("w{i}")), *want);
        }
        assert_eq!(a.color_for("w10"), PALETTE[0]);
        assert_eq!(a.color_for("w11"), PALETTE[1]);
    }
}
