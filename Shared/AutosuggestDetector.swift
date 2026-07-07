import Foundation

/// Detects the terminal's inline autosuggestion — the greyed "ghost text" that
/// zsh-autosuggestions, fish, and Claude Code inline suggest render after the
/// cursor. Both peers share this one source: the Mac uses it to broadcast a
/// per-window hasAutosuggest flag and to guard Right-arrow injection, the phone
/// uses the flag to gate its accept-autocomplete button.
///
/// A suggestion is a TRAILING run on the LAST non-empty line styled dim/faint
/// (SGR 2) or grey foreground (SGR 90, or 8-bit greys 38;5;8 / 38;5;236-245),
/// immediately preceded on that line by non-dim text (the user's typed input).
/// A fully-dim line is not a suggestion (that's a hint/comment line), and dim
/// text in scrollback (any earlier line) never triggers.
///
/// Foundation-only (no AppKit/UIKit/SwiftUI) so it compiles in the swiftc
/// assertion harness (tools/run-autosuggest-tests.sh) with no Xcode,
/// simulator, or signing.
enum AutosuggestDetector {

    /// The ANSI-stripped text of the inline suggestion on the last non-empty
    /// line of `content`, or nil when nothing is showing.
    static func suggestionText(in content: String) -> String? {
        guard !content.isEmpty else { return nil }

        // Only the LAST non-empty line can carry the input-line suggestion;
        // dim runs in scrollback must not trigger.
        var lastLine: [StyledCharacter]? = nil
        for line in content.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let chars = styledCharacters(of: String(line))
            if chars.contains(where: { !$0.char.isWhitespace }) {
                lastLine = chars
                break
            }
        }
        guard var chars = lastLine else { return nil }

        // Terminal scrapes pad lines with default-styled spaces; they don't
        // break a trailing suggestion run.
        while let last = chars.last, last.char.isWhitespace { chars.removeLast() }

        guard chars.last?.suggestionStyled == true else { return nil }

        var start = chars.count
        while start > 0, chars[start - 1].suggestionStyled { start -= 1 }

        // The run must be preceded by the user's typed (non-dim) input on the
        // same line — a run spanning the whole line is a hint, not a suggestion.
        guard start > 0,
              chars[..<start].contains(where: { !$0.suggestionStyled && !$0.char.isWhitespace })
        else { return nil }

        return String(chars[start...].map(\.char))
    }

    /// True when `suggestionText(in:)` finds a suggestion.
    static func hasSuggestion(in content: String) -> Bool {
        suggestionText(in: content) != nil
    }

    /// Pure inject-time decision the Mac's press_right handler consults: a tap
    /// that raced the screen (suggestion gone by inject time) must be dropped,
    /// never injected into empty air where Right-arrow would move the cursor
    /// into the user's typed text.
    static func shouldAccept(liveContent: String) -> Bool {
        hasSuggestion(in: liveContent)
    }

    // MARK: - ANSI parsing

    private struct StyledCharacter {
        let char: Character
        let suggestionStyled: Bool
    }

    /// Visible characters of one line, each tagged with whether the active SGR
    /// style at that point qualifies as suggestion styling (dim or grey fg).
    /// Non-SGR escapes (other CSI, OSC, two-char ESC sequences) are stripped.
    private static func styledCharacters(of line: String) -> [StyledCharacter] {
        var result: [StyledCharacter] = []
        var dim = false
        var greyForeground = false
        var i = line.startIndex

        while i < line.endIndex {
            let c = line[i]
            guard c == "\u{1B}" else {
                result.append(StyledCharacter(char: c, suggestionStyled: dim || greyForeground))
                i = line.index(after: i)
                continue
            }

            i = line.index(after: i)
            guard i < line.endIndex else { break }

            switch line[i] {
            case "[":
                // CSI: parameter/intermediate bytes, then one final byte @-~.
                i = line.index(after: i)
                var params = ""
                while i < line.endIndex, !("\u{40}"..."\u{7E}").contains(line[i]) {
                    params.append(line[i])
                    i = line.index(after: i)
                }
                if i < line.endIndex {
                    let final = line[i]
                    i = line.index(after: i)
                    if final == "m" {
                        applySGR(params, dim: &dim, greyForeground: &greyForeground)
                    }
                }
            case "]":
                // OSC: swallow through BEL or ST (ESC \).
                i = line.index(after: i)
                while i < line.endIndex {
                    if line[i] == "\u{07}" {
                        i = line.index(after: i)
                        break
                    }
                    let next = line.index(after: i)
                    if line[i] == "\u{1B}", next < line.endIndex, line[next] == "\\" {
                        i = line.index(after: next)
                        break
                    }
                    i = line.index(after: i)
                }
            default:
                // Two-character escape (charset select, etc.) — skip it.
                i = line.index(after: i)
            }
        }
        return result
    }

    /// Applies one SGR parameter string ("2", "0", "38;5;240", "" == reset) to
    /// the dim / grey-foreground state.
    private static func applySGR(_ params: String, dim: inout Bool, greyForeground: inout Bool) {
        let codes = params
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        let list = codes.isEmpty ? [0] : codes

        var idx = 0
        while idx < list.count {
            switch list[idx] {
            case 0:
                dim = false
                greyForeground = false
            case 2:
                dim = true
            case 22:                       // normal intensity — cancels dim
                dim = false
            case 90:                       // bright black == grey
                greyForeground = true
            case 39, 30...37, 91...97:     // any other named fg cancels grey
                greyForeground = false
            case 38:                       // extended fg: 38;5;N or 38;2;R;G;B
                if idx + 2 < list.count, list[idx + 1] == 5 {
                    let n = list[idx + 2]
                    greyForeground = n == 8 || (236...245).contains(n)
                    idx += 2
                } else if idx + 1 < list.count, list[idx + 1] == 2 {
                    greyForeground = false
                    idx += min(4, list.count - idx - 1)
                }
            default:
                break
            }
            idx += 1
        }
    }
}
