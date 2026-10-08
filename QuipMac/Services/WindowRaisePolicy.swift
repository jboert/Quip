import CoreGraphics
import Foundation

/// Whether an injection raises its window first (PRD broadcast-and-search,
/// US-116).
///
/// A broadcast to many iTerm2 windows used to raise each one in turn, since
/// every `send_text` called `focusWindow` before injecting. iTerm2 writes
/// are addressed to a session id and land without focus, so a request that
/// says `raiseWindow: false` skips the raise there. Terminal.app keystrokes
/// go to the frontmost window, but the script raises and verifies its own
/// window by id (`KeystrokeInjector.terminalWindowGuard`) on the one serial
/// AppleScript queue, so a quiet request with a window number skips the
/// Accessibility raise too: that raise runs on the main actor outside the
/// queue, and in a broadcast a later target's raise could re-front its
/// window while an earlier target's script was still typing. Without a
/// window number the script only activates Terminal, so the raise stays.
/// Claude Desktop and generic apps take a paste into the active app, so
/// those are always raised whatever the request says. No request (an older
/// phone) keeps today's behaviour: raise.
enum WindowRaisePolicy {
    static func shouldRaise(requested: Bool?, terminalApp: TerminalApp, isGenericApp: Bool,
                            cgWindowNumber: CGWindowID = 0) -> Bool {
        guard requested == false else { return true }
        if isGenericApp { return true }
        switch terminalApp {
        case .iterm2: return false
        case .terminal: return cgWindowNumber == 0
        case .claudeDesktop: return true
        }
    }
}

/// What the Mac answers after an injection (US-115): one `send_text_ack`
/// per success, one `error` per failure, each carrying the request's
/// `messageId` so the phone can settle that one target of a broadcast. A
/// request without an id (an older phone) gets the error but no ack, as
/// `send_text` always did.
enum InjectionReply {
    struct Messages: Equatable {
        var ack: SendTextAckMessage?
        var error: ErrorMessage?
    }

    static func messages(result: KeystrokeInjector.InjectionResult, messageId: UUID?,
                         injectMs: Int, totalMs: Int, path: String, failurePrefix: String) -> Messages {
        if result.success {
            guard let messageId else { return Messages() }
            return Messages(ack: SendTextAckMessage(messageId: messageId, injectMs: injectMs,
                                                    totalMs: totalMs, path: path))
        }
        let reason = "\(failurePrefix): \(result.error ?? "unknown injection failure")"
        return Messages(error: ErrorMessage(reason: reason, messageId: messageId))
    }
}

extension SendTextAckMessage: Equatable {
    static func == (lhs: SendTextAckMessage, rhs: SendTextAckMessage) -> Bool {
        lhs.messageId == rhs.messageId && lhs.injectMs == rhs.injectMs
            && lhs.totalMs == rhs.totalMs && lhs.path == rhs.path
    }
}

extension ErrorMessage: Equatable {
    static func == (lhs: ErrorMessage, rhs: ErrorMessage) -> Bool {
        lhs.reason == rhs.reason && lhs.messageId == rhs.messageId
    }
}
