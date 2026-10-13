import SwiftUI
import AVFoundation

/// Tab selection for the Spawn Window sheet. "New" is the original path —
/// project directories the Mac reports — and "Attach Existing" is the new
/// flow that lets the user pick an iTerm window already open on the Mac.
/// Keeping them in one sheet (vs two separate buttons on the main bar) keeps
/// chrome off the main screen; both actions live behind the same "+" tap.
enum SpawnSheetTab: String, CaseIterable, Identifiable {
    case new = "New"
    case attach = "Attach Existing"
    var id: String { rawValue }
}

extension SpawnAgent {
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .terminal: return "Terminal"
        case .cursor: return "Cursor"
        }
    }
}
