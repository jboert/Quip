//! Value types shared by several messages.

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// Terminal state, `TerminalState` raw values on the Mac. Phase 1 only ever
/// sends `neutral` (waiting-state detection is phase 2), but the other values
/// are kept so a decoded `state_change` round-trips.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
pub enum TerminalState {
    #[serde(rename = "neutral")]
    #[default]
    Neutral,
    #[serde(rename = "waiting_for_input")]
    WaitingForInput,
    #[serde(rename = "stt_active")]
    SttActive,
}

impl TerminalState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Neutral => "neutral",
            Self::WaitingForInput => "waiting_for_input",
            Self::SttActive => "stt_active",
        }
    }
}

/// `WindowFrame` in `Shared/MessageProtocol.swift`: normalized 0..1 against the
/// window's own display. Four required doubles.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub struct WindowFrame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl WindowFrame {
    pub const ZERO: WindowFrame = WindowFrame { x: 0.0, y: 0.0, width: 0.0, height: 0.0 };
    pub const UNIT: WindowFrame = WindowFrame { x: 0.0, y: 0.0, width: 1.0, height: 1.0 };
}

/// `CLIKind` in `Shared/MessageProtocol.swift`. Every Windows terminal is
/// `shell` in phase 1 (no agent detection yet).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CliKind {
    Claude,
    Codex,
    Grok,
    Shell,
    Cursor,
}

impl CliKind {
    pub const ALL: [CliKind; 5] = [CliKind::Claude, CliKind::Codex, CliKind::Grok, CliKind::Shell, CliKind::Cursor];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Grok => "grok",
            Self::Shell => "shell",
            Self::Cursor => "cursor",
        }
    }
}

/// `ArrangeLayout` in `Shared/MessageProtocol.swift`. A closed enum on purpose
/// (GH #20): an unknown layout fails decode instead of silently doing nothing.
/// The QuipLinux copy carried it as a free `String`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ArrangeLayout {
    Horizontal,
    Vertical,
}

/// A Swift `UUID` on the wire.
///
/// Swift's `JSONDecoder` accepts only the 36-character hyphenated form (either
/// case) and `JSONEncoder` writes it in UPPER case. The `uuid` crate is more
/// lenient on input (braces, urn:, 32-hex "simple") and writes lower case, so
/// it is wrapped: a message the Mac would reject is rejected here too, and an
/// echoed id reads exactly as the Mac would write it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct WireUuid(pub uuid::Uuid);

impl WireUuid {
    pub fn new_v4() -> Self {
        WireUuid(uuid::Uuid::new_v4())
    }

    /// Parse the Swift `UUID(uuidString:)` way: 36 chars, hyphenated.
    pub fn parse(s: &str) -> Option<Self> {
        if s.len() != 36 {
            return None;
        }
        let b = s.as_bytes();
        if b[8] != b'-' || b[13] != b'-' || b[18] != b'-' || b[23] != b'-' {
            return None;
        }
        uuid::Uuid::parse_str(s).ok().map(WireUuid)
    }

    /// Upper-case hyphenated, as Swift's `uuidString`.
    pub fn to_swift_string(self) -> String {
        self.0.hyphenated().to_string().to_uppercase()
    }

    /// First 8 characters, as the Mac's `latency.log` `rid=` field.
    pub fn short(self) -> String {
        self.to_swift_string().chars().take(8).collect()
    }
}

impl Serialize for WireUuid {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.to_swift_string())
    }
}

impl<'de> Deserialize<'de> for WireUuid {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        WireUuid::parse(&s).ok_or_else(|| serde::de::Error::custom(format!("invalid UUID string: {s:?}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uuid_accepts_either_case_hyphenated() {
        assert!(WireUuid::parse("6ba7b810-9dad-11d1-80b4-00c04fd430c8").is_some());
        assert!(WireUuid::parse("6BA7B810-9DAD-11D1-80B4-00C04FD430C8").is_some());
    }

    #[test]
    fn uuid_rejects_forms_swift_rejects() {
        assert!(WireUuid::parse("6ba7b8109dad11d180b400c04fd430c8").is_none());
        assert!(WireUuid::parse("{6ba7b810-9dad-11d1-80b4-00c04fd430c8}").is_none());
        assert!(WireUuid::parse("urn:uuid:6ba7b810-9dad-11d1-80b4-00c04fd430c8").is_none());
        assert!(WireUuid::parse("").is_none());
        assert!(WireUuid::parse("6ba7b810-9dad-11d1-80b4-00c04fd430cZ").is_none());
    }

    #[test]
    fn uuid_encodes_upper_case_like_swift() {
        let id = WireUuid::parse("6ba7b810-9dad-11d1-80b4-00c04fd430c8").unwrap();
        assert_eq!(serde_json::to_string(&id).unwrap(), "\"6BA7B810-9DAD-11D1-80B4-00C04FD430C8\"");
        assert_eq!(id.short(), "6BA7B810");
    }

    #[test]
    fn cli_kind_raw_values() {
        for k in CliKind::ALL {
            assert_eq!(serde_json::to_string(&k).unwrap(), format!("\"{}\"", k.as_str()));
        }
    }

    #[test]
    fn arrange_layout_rejects_grid_and_uppercase() {
        assert!(serde_json::from_str::<ArrangeLayout>("\"grid\"").is_err());
        assert!(serde_json::from_str::<ArrangeLayout>("\"HORIZONTAL\"").is_err());
        assert_eq!(serde_json::from_str::<ArrangeLayout>("\"vertical\"").unwrap(), ArrangeLayout::Vertical);
    }

    #[test]
    fn terminal_state_raw_values() {
        assert_eq!(TerminalState::default().as_str(), "neutral");
        assert_eq!(serde_json::to_string(&TerminalState::WaitingForInput).unwrap(), "\"waiting_for_input\"");
    }
}
