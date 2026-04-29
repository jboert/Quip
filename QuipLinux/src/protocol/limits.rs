//! Cross-platform protocol invariants. Mirror of `Shared/Constants.swift`'s
//! `WSLimits` — when one side raises a cap, the other side has to match or
//! large messages get silently dropped on whichever peer enforces the smaller
//! number. CLAUDE.md's "two separate size caps" debugging note is the war
//! story; that's why this lives in one place now.

/// Maximum allowed WebSocket message size, in bytes. Sized to fit base64-
/// encoded full-resolution phone photos with headroom for TTS audio bursts.
/// Tungstenite's defaults (64 MiB protocol max, 16 MiB frame max) sit at or
/// above this app-layer cap, so this is the binding limit.
pub const MAX_MESSAGE_BYTES: usize = 16 * 1024 * 1024;
