import Foundation

/// Says when the terminal panel is showing something the Mac has stopped
/// answering for (Q-62).
///
/// The panel asks for the selected window every 2 s and the Mac answers every
/// request, except one for a window id it no longer tracks. So a closed
/// window, a sleeping Mac and a socket that died without a close all look the
/// same on the phone: "Loading…" that never ends, or the last text frozen with
/// nothing to say it is old.
enum TerminalPanelFreshness {
    /// Five missed refreshes. Short enough to notice, long enough that one
    /// slow screenshot never flashes the chip.
    static let staleAfter: TimeInterval = 10
    /// Four missed refreshes before the loading text stops saying "Loading…".
    static let slowLoadingAfter: TimeInterval = 8

    /// Short header chip, "15 s old", or nil while the text is fresh or has
    /// never arrived (the loading branch covers that case).
    static func staleLabel(lastUpdate: Date?, now: Date) -> String? {
        guard let age = staleAge(lastUpdate: lastUpdate, now: now) else { return nil }
        switch age {
        case ..<60: return "\(Int(age)) s old"
        case ..<3600: return "\(Int(age / 60)) min old"
        default: return "\(Int(age / 3600)) h old"
        }
    }

    /// VoiceOver wording for the same chip.
    static func spokenStaleLabel(lastUpdate: Date?, now: Date) -> String? {
        guard let age = staleAge(lastUpdate: lastUpdate, now: now) else { return nil }
        let (n, unit): (Int, String) = switch age {
        case ..<60: (Int(age), "second")
        case ..<3600: (Int(age / 60), "minute")
        default: (Int(age / 3600), "hour")
        }
        return "No update from the Mac for \(n) \(unit)\(n == 1 ? "" : "s")"
    }

    /// The loading branch's text: `base` at first, then why it is taking so
    /// long. The panel keeps asking, so the text says that too.
    static func loadingText(base: String, waitingSince: Date?, now: Date) -> String {
        guard let waitingSince, now.timeIntervalSince(waitingSince) >= slowLoadingAfter else { return base }
        return "No reply from the Mac for this window. It may have closed, or the Mac may be asleep or offline. Still asking every 2 s."
    }

    private static func staleAge(lastUpdate: Date?, now: Date) -> TimeInterval? {
        guard let lastUpdate else { return nil }
        let age = now.timeIntervalSince(lastUpdate)
        return age >= staleAfter ? age : nil
    }
}
