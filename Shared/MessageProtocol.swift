import Foundation

// MARK: - Message Envelope

struct WSMessage: Codable {
    let type: String
}

// MARK: - Mac → iPhone Messages

struct LayoutUpdate: Codable, Sendable {
    let type: String
    let monitor: String
    let windows: [WindowState]

    init(monitor: String, windows: [WindowState]) {
        self.type = "layout_update"
        self.monitor = monitor
        self.windows = windows
    }
}

struct WindowState: Codable, Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let name: String
    let app: String
    let enabled: Bool
    let frame: WindowFrame
    let state: String
    let color: String

    // Synthesized Equatable compares ALL fields including frame
}

struct WindowFrame: Codable, Sendable, Equatable, Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct StateChangeMessage: Codable, Sendable {
    let type: String
    let windowId: String
    let state: String

    init(windowId: String, state: String) {
        self.type = "state_change"
        self.windowId = windowId
        self.state = state
    }
}

// MARK: - iPhone → Mac Messages

struct SelectWindowMessage: Codable, Sendable {
    let type: String
    let windowId: String

    init(windowId: String) {
        self.type = "select_window"
        self.windowId = windowId
    }
}

struct SendTextMessage: Codable, Sendable {
    let type: String
    let windowId: String
    let text: String
    let pressReturn: Bool

    init(windowId: String, text: String, pressReturn: Bool = true) {
        self.type = "send_text"
        self.windowId = windowId
        self.text = text
        self.pressReturn = pressReturn
    }
}

struct QuickActionMessage: Codable, Sendable {
    let type: String
    let windowId: String
    let action: String

    init(windowId: String, action: String) {
        self.type = "quick_action"
        self.windowId = windowId
        self.action = action
    }
}

struct STTStateMessage: Codable, Sendable {
    let type: String
    let windowId: String

    init(type: String, windowId: String) {
        self.type = type
        self.windowId = windowId
    }

    static func started(windowId: String) -> STTStateMessage {
        STTStateMessage(type: "stt_started", windowId: windowId)
    }

    static func ended(windowId: String) -> STTStateMessage {
        STTStateMessage(type: "stt_ended", windowId: windowId)
    }
}

struct RequestContentMessage: Codable, Sendable {
    let type: String
    let windowId: String

    init(windowId: String) {
        self.type = "request_content"
        self.windowId = windowId
    }
}

struct TerminalContentMessage: Codable, Sendable {
    let type: String
    let windowId: String
    let content: String
    let screenshot: String?

    init(windowId: String, content: String, screenshot: String? = nil) {
        self.type = "terminal_content"
        self.windowId = windowId
        self.content = content
        self.screenshot = screenshot
    }
}

struct OutputDeltaMessage: Codable, Sendable {
    let type: String
    let windowId: String
    let windowName: String
    let text: String
    let isFinal: Bool

    init(windowId: String, windowName: String, text: String, isFinal: Bool = true) {
        self.type = "output_delta"
        self.windowId = windowId
        self.windowName = windowName
        self.text = text
        self.isFinal = isFinal
    }
}

// MARK: - Authentication Messages

struct AuthMessage: Codable, Sendable {
    let type: String
    let pin: String

    init(pin: String) {
        self.type = "auth"
        self.pin = pin
    }
}

struct AuthResultMessage: Codable, Sendable {
    let type: String
    let success: Bool
    let error: String?

    init(success: Bool, error: String? = nil) {
        self.type = "auth_result"
        self.success = success
        self.error = error
    }
}

// MARK: - Message Encoding/Decoding Helpers

enum MessageCoder {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    static let decoder = JSONDecoder()

    static func encode<T: Codable>(_ message: T) -> Data? {
        try? encoder.encode(message)
    }

    static func decode<T: Codable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder.decode(type, from: data)
    }

    static func messageType(from data: Data) -> String? {
        guard let envelope = try? decoder.decode(WSMessage.self, from: data) else { return nil }
        return envelope.type
    }
}
