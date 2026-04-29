import Foundation

// MARK: - WebSocket Protocol Limits

/// Cross-platform invariants that have to match between every WebSocket peer.
/// CLAUDE.md's "two separate size caps" debugging note exists because these
/// numbers used to live inline in three files; mismatches silently dropped
/// image uploads. Edit here, propagate everywhere.
///
/// Mirror in:
///   - QuipLinux/src/protocol/limits.rs (`MAX_MESSAGE_BYTES`)
///   - QuipAndroid (when an explicit cap is added; OkHttp's default is ample
///     for now but should be pinned to this value when image upload lands).
enum WSLimits {
    /// Maximum allowed WebSocket message size, in bytes. Enforced both at
    /// the protocol layer (`NWProtocolWebSocket.Options.maximumMessageSize`,
    /// `URLSessionWebSocketTask.maximumMessageSize`) and at the application
    /// layer in the receive loop. Sized to fit base64-encoded full-resolution
    /// phone photos (~7-10 MB encoded) with headroom for TTS audio bursts.
    static let maxMessageBytes: Int = 16 * 1024 * 1024
}
