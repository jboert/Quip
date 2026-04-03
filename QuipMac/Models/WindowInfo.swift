import AppKit

// MARK: - Terminal App Selection

enum TerminalApp: String, Codable, CaseIterable, Identifiable, Sendable {
    case terminal = "Terminal"
    case iterm2 = "iTerm2"

    var id: String { rawValue }

    var bundleIdentifier: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm2: "com.googlecode.iterm2"
        }
    }
}

// MARK: - Terminal State

enum TerminalState: String, Codable, Sendable {
    case neutral
    case waitingForInput = "waiting_for_input"
    case sttActive = "stt_active"
}
