// InputLineSend.swift
// Shared — what "send" means when the Mac's input line already holds text

import Foundation

/// Rules for the compose field once an accepted autosuggestion has been echoed
/// into it.
///
/// Accepting a suggestion types it on the MAC. The phone then shows the same
/// text, so the user can see what is on the line — but that text is no longer
/// something to send: typing it again would double it
/// (`git commitgit commit`). Nor can the phone quietly ignore an edited field,
/// because the stale text is still sitting on the Mac's input line.
///
/// Two rules cover it, both pure so they are testable without a WebSocket and
/// cannot drift between the two send affordances (the up-arrow and the Return
/// button):
///
/// - `plan(fieldText:lineEcho:)` — what the send button does.
/// - `shouldClearMacLine(fieldText:lineEcho:)` — whether the user has just
///   edited the echo, which means the Mac's line has to be wiped BEFORE
///   anything else is typed. The phone sends that wipe at edit time, not at
///   send time: two messages separated by human typing arrive in order, two
///   fired back to back from the same tap do not (they are scheduled
///   independently on the Mac, each with its own focus delay).
enum InputLineSend {

    enum Plan: Equatable {
        /// Ordinary text to type and submit.
        case typeAndReturn(String)
        /// The field still matches what the accept echoed — the Mac already has
        /// this text on its input line, so submit it and type nothing.
        case returnOnly
    }

    /// `nil` means "there is nothing to send" — the caller keeps whatever it
    /// already does for an empty field (bare Return, image-only submit).
    ///
    /// `lineEcho` is the text the phone echoed after accepting a suggestion for
    /// the window being sent to, or nil when there is no such echo.
    static func plan(fieldText: String, lineEcho: String?) -> Plan? {
        // Compared untrimmed: the echo is a verbatim copy of the Mac's line, so
        // a user who added a trailing space HAS edited it.
        if let echo = lineEcho, fieldText == echo { return .returnOnly }

        let trimmed = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : .typeAndReturn(trimmed)
    }

    /// True when the field no longer matches the echo, i.e. the user edited
    /// text that is already on the Mac's input line. The caller wipes the line
    /// (`clear_input`, Ctrl+U) and forgets the echo, after which the field is
    /// an ordinary compose box again.
    static func shouldClearMacLine(fieldText: String, lineEcho: String?) -> Bool {
        guard let echo = lineEcho else { return false }
        return fieldText != echo
    }
}
