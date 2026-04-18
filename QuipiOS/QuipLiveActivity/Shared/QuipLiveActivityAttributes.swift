import Foundation
import ActivityKit

/// Attributes + dynamic state for a Claude window's Live Activity. One
/// activity per tracked window; the user's currently-selected window is
/// the only one that gets an activity in v1 (PRD FR-12).
///
/// This file is included in BOTH the main app target and the
/// QuipLiveActivity extension target so the two sides agree on layout.
/// (Attributes must be Codable; ContentState nested type must also be
/// Codable — ActivityAttributes requires it.)
struct QuipLiveActivityAttributes: ActivityAttributes {

    /// Matches the "thinking" vs "waiting for input" UX of the PRD.
    /// Kept as a plain string so future additions (e.g. "error") don't
    /// break an older app/widget pair out in the wild.
    public struct ContentState: Codable, Hashable {
        /// "thinking" or "waiting" — anything else renders as "thinking"
        /// to be forgiving.
        public var state: String

        public init(state: String) { self.state = state }
    }

    /// iTerm/Quip window identity — used by the "Open Quip" button's
    /// deep-link URL (quip://window/<id>) so taps route to the right
    /// window once the app opens.
    public var windowId: String

    /// Human-readable window name (e.g. "claude"). Shown in the
    /// expanded island and lock-screen presentation.
    public var windowName: String

    public init(windowId: String, windowName: String) {
        self.windowId = windowId
        self.windowName = windowName
    }
}
