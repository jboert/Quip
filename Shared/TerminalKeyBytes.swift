import Foundation

/// Authoritative map from arrow/navigation key names to the raw ANSI CSI byte
/// sequences a terminal expects. Both peers and the Mac keystroke injector share
/// this one source so the bytes that accept an autocomplete suggestion never drift.
///
/// Foundation-only (no AppKit/UIKit/SwiftUI) so it compiles in the swiftc
/// assertion harness (tools/run-accept-autocomplete-tests.sh) with no Xcode,
/// simulator, or signing.
enum TerminalKeyBytes {
    /// Raw escape sequence for a key name, or nil for an unknown key.
    ///
    /// `"right"` is the PRIMARY accept-autocomplete key: zsh-autosuggestions,
    /// fish, and Claude Code inline suggest all commit the greyed ghost text on
    /// Right-arrow. `"end"` is the ALTERNATE — some prompts accept on End instead
    /// of Right — so both are exposed and a UI can swap one for the other.
    ///
    /// Case-insensitive.
    static func csi(for key: String) -> String? {
        switch key.lowercased() {
        case "up":    return "\u{1B}[A"
        case "down":  return "\u{1B}[B"
        case "right": return "\u{1B}[C"   // primary accept-autocomplete key
        case "left":  return "\u{1B}[D"
        case "end":   return "\u{1B}[F"   // alternate accept-autocomplete key
        default:      return nil
        }
    }
}
