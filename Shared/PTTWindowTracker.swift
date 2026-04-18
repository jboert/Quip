import Foundation

/// Pins the target windowId for a single push-to-talk recording session.
///
/// Motivation: on iPhone, `selectedWindowId` can change *during* a recording —
/// the Mac may push a `select_window` message, or the currently selected
/// window may disappear from a layout update and auto-reassign to the next
/// one. If stopRecording re-read `selectedWindowId` at release time, the
/// transcription would get routed to whichever window happened to be selected
/// at that instant, not the one the user was looking at when they pressed
/// PTT. Capturing at `begin` and reading back at `end` defeats that race.
///
/// Value type — owned by QuipApp as `@State` and mutated on MainActor.
struct PTTWindowTracker {
    private var capturedWindowId: String?

    var isActive: Bool { capturedWindowId != nil }

    mutating func begin(windowId: String) {
        capturedWindowId = windowId
    }

    /// Returns the windowId captured at `begin(...)`, then clears it. A second
    /// call without an intervening `begin` returns nil — deliberate, so a
    /// duplicate stop can't double-fire against a stale id.
    mutating func end() -> String? {
        let id = capturedWindowId
        capturedWindowId = nil
        return id
    }
}
