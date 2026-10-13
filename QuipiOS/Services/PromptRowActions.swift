import Foundation

/// What a prompt row in the Prompts hub offers (Q-51 / US-209): the same
/// actions in its hold menu as anywhere a prompt appears, and one swipe rule,
/// right to send and left to manage.
enum PromptRowAction: Equatable {
    case paste, pasteAndSend, sendTo, broadcast, edit, hide, show, delete

    var title: String {
        switch self {
        case .paste: return "Paste"
        case .pasteAndSend: return "Paste and Send"
        case .sendTo: return "Send to…"
        case .broadcast: return "Broadcast…"
        case .edit: return "Edit…"
        case .hide: return "Hide"
        case .show: return "Show"
        case .delete: return "Delete…"
        }
    }

    var systemImage: String {
        switch self {
        case .paste: return "doc.on.clipboard"
        case .pasteAndSend: return "return"
        case .sendTo: return "arrow.up.forward.app"
        case .broadcast: return "dot.radiowaves.left.and.right"
        case .edit: return "pencil"
        case .hide: return "eye.slash"
        case .show: return "eye"
        case .delete: return "trash"
        }
    }
}

enum PromptRowActions {
    static func menu(hidden: Bool) -> [PromptRowAction] {
        [.paste, .pasteAndSend, .sendTo, .broadcast, .edit, hidden ? .show : .hide, .delete]
    }

    /// Swipe right. The first action is the one a full swipe runs, so it is
    /// Send to…, which only opens a list, never a send by itself.
    static let leadingSwipe: [PromptRowAction] = [.sendTo, .pasteAndSend, .broadcast]

    /// Swipe left. Delete leads, as before, and still asks first.
    static func trailingSwipe(hidden: Bool) -> [PromptRowAction] {
        [.delete, hidden ? .show : .hide, .edit]
    }
}
