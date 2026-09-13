import Foundation

/// Canonical prompt-id sanitizer, shared by both peers.
///
/// The Mac derives the on-disk filename (`<id>.txt` under
/// `~/Library/Application Support/Quip/prompts/`) from this, and the iOS editor
/// runs the same function to show the user what their id will become *before*
/// they save. Keeping one implementation is the point: a phone-side mirror that
/// drifted would promise one filename and the Mac would write another.
///
/// Allowed through: letters, digits, dash, underscore, dot. Spaces become
/// dashes. Everything else — path separators, shell metacharacters — is dropped
/// so a hostile id such as `../../../etc/passwd` cannot escape the prompts
/// directory. Leading dots are stripped so an id can never produce a hidden
/// file or resolve to `.`/`..`. An empty result means "reject this id"; callers
/// must not write it.
enum PromptID {

    static func sanitize(_ raw: String) -> String {
        var out = ""
        for ch in raw {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "." {
                out.append(ch)
            } else if ch == " " {
                out.append("-")
            }
        }
        while out.first == "." { out.removeFirst() }
        return out
    }

    /// True when `raw` sanitizes onto an id that already exists. Used by the
    /// new-prompt flow to warn before a save silently overwrites a neighbour:
    /// two visibly different ids ("ship it" and "ship/it") land on one file.
    /// An id that sanitizes to nothing never collides — it is rejected first.
    static func collides(_ raw: String, with existingIDs: Set<String>) -> Bool {
        let clean = sanitize(raw)
        guard !clean.isEmpty else { return false }
        return existingIDs.contains(clean)
    }
}
