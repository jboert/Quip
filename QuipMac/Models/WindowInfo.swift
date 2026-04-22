import AppKit

// MARK: - Terminal App Selection

enum TerminalApp: String, Codable, CaseIterable, Identifiable, Sendable {
    case iterm2 = "iTerm2"
    case terminal = "Terminal"
    case claudeDesktop = "Claude"

    var id: String { rawValue }

    var bundleIdentifier: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm2: "com.googlecode.iterm2"
        case .claudeDesktop: "com.anthropic.Claude"
        }
    }

    static func fromBundleId(_ bundleId: String) -> TerminalApp {
        switch bundleId {
        case "com.apple.Terminal": return .terminal
        case "com.anthropic.Claude": return .claudeDesktop
        default: return .iterm2
        }
    }
}

// MARK: - Terminal State

enum TerminalState: String, Codable, Sendable {
    case neutral
    case waitingForInput = "waiting_for_input"
    case sttActive = "stt_active"
}
