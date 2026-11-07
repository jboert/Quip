//! Cross-platform protocol invariants. Mirror of `Shared/Constants.swift`'s
//! `WSLimits`: when one peer raises a cap the others have to match, or large
//! messages are silently dropped by whichever peer enforces the smaller number
//! (CLAUDE.md, "the 16 MiB cap is enforced at TWO layers").

/// Maximum allowed WebSocket message size, in bytes, at the application
/// layer. `WSLimits.maxMessageBytes` in `Shared/Constants.swift`.
pub const MAX_MESSAGE_BYTES: usize = 16 * 1024 * 1024;

/// Room above the app cap at the protocol level, so a message just over
/// 16 MiB still reaches the app-level check (dropped and logged, the socket
/// stays open, spec 3) instead of tungstenite failing the connection.
pub const PROTOCOL_HEADROOM_BYTES: usize = 64 * 1024;

/// Protocol-level ceiling handed to tungstenite: the app cap plus a little
/// headroom. Anything larger fails the connection, which bounds what one
/// peer can make the host buffer (the Mac's `maximumMessageSize` is the app
/// cap itself).
pub const PROTOCOL_MAX_MESSAGE_BYTES: usize = MAX_MESSAGE_BYTES + PROTOCOL_HEADROOM_BYTES;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn app_cap_matches_shared_constants_swift() {
        // `static let maxMessageBytes: Int = 16 * 1024 * 1024`
        assert_eq!(MAX_MESSAGE_BYTES, 16_777_216);
    }

    #[test]
    fn protocol_cap_sits_just_above_app_cap() {
        const { assert!(PROTOCOL_MAX_MESSAGE_BYTES > MAX_MESSAGE_BYTES) };
        const { assert!(PROTOCOL_MAX_MESSAGE_BYTES <= MAX_MESSAGE_BYTES + 1024 * 1024, "headroom, not a second cap") };
        assert_eq!(PROTOCOL_MAX_MESSAGE_BYTES, 16 * 1024 * 1024 + 64 * 1024);
    }
}
