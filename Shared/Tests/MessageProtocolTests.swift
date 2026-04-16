import XCTest
@testable import Quip

/// Unit tests for MessageProtocol encoding/decoding.
/// Verifies that all message types produce the expected JSON structure
/// and can be round-tripped through encode/decode, ensuring cross-platform
/// compatibility with the Android Protocol.kt.
final class MessageProtocolTests: XCTestCase {

    // MARK: - Outgoing messages (iPhone → Mac)

    func testSelectWindowMessageEncoding() throws {
        let msg = SelectWindowMessage(windowId: "win-123")
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let dict = try jsonDict(from: data)

        XCTAssertEqual(dict["type"] as? String, "select_window")
        XCTAssertEqual(dict["windowId"] as? String, "win-123")
    }

    func testSendTextMessageEncoding() throws {
        let msg = SendTextMessage(windowId: "win-1", text: "hello world")
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let dict = try jsonDict(from: data)

        XCTAssertEqual(dict["type"] as? String, "send_text")
        XCTAssertEqual(dict["windowId"] as? String, "win-1")
        XCTAssertEqual(dict["text"] as? String, "hello world")
        XCTAssertEqual(dict["pressReturn"] as? Bool, true)
    }

    func testSendTextMessagePressReturnFalse() throws {
        let msg = SendTextMessage(windowId: "win-1", text: "hi", pressReturn: false)
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let dict = try jsonDict(from: data)

        XCTAssertEqual(dict["pressReturn"] as? Bool, false)
    }

    func testQuickActionMessageEncoding() throws {
        let msg = QuickActionMessage(windowId: "win-2", action: "press_ctrl_c")
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let dict = try jsonDict(from: data)

        XCTAssertEqual(dict["type"] as? String, "quick_action")
        XCTAssertEqual(dict["windowId"] as? String, "win-2")
        XCTAssertEqual(dict["action"] as? String, "press_ctrl_c")
    }

    func testSTTStateMessageStarted() throws {
        let msg = STTStateMessage.started(windowId: "win-5")
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let dict = try jsonDict(from: data)

        XCTAssertEqual(dict["type"] as? String, "stt_started")
        XCTAssertEqual(dict["windowId"] as? String, "win-5")
    }

    func testSTTStateMessageEnded() throws {
        let msg = STTStateMessage.ended(windowId: "win-5")
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let dict = try jsonDict(from: data)

        XCTAssertEqual(dict["type"] as? String, "stt_ended")
        XCTAssertEqual(dict["windowId"] as? String, "win-5")
    }

    func testRequestContentMessageEncoding() throws {
        let msg = RequestContentMessage(windowId: "win-3")
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let dict = try jsonDict(from: data)

        XCTAssertEqual(dict["type"] as? String, "request_content")
        XCTAssertEqual(dict["windowId"] as? String, "win-3")
    }

    // MARK: - Authentication messages

    func testAuthMessageEncoding() throws {
        let msg = AuthMessage(pin: "123456")
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let dict = try jsonDict(from: data)

        XCTAssertEqual(dict["type"] as? String, "auth")
        XCTAssertEqual(dict["pin"] as? String, "123456")
    }

    func testAuthMessageRoundTrip() throws {
        let original = AuthMessage(pin: "987654")
        let data = try XCTUnwrap(MessageCoder.encode(original))
        let restored = try XCTUnwrap(MessageCoder.decode(AuthMessage.self, from: data))
        XCTAssertEqual(original.pin, restored.pin)
        XCTAssertEqual(original.type, restored.type)
    }

    func testAuthResultSuccessEncoding() throws {
        let msg = AuthResultMessage(success: true)
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let dict = try jsonDict(from: data)

        XCTAssertEqual(dict["type"] as? String, "auth_result")
        XCTAssertEqual(dict["success"] as? Bool, true)
    }

    func testAuthResultFailureEncoding() throws {
        let msg = AuthResultMessage(success: false, error: "Invalid PIN")
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let dict = try jsonDict(from: data)

        XCTAssertEqual(dict["type"] as? String, "auth_result")
        XCTAssertEqual(dict["success"] as? Bool, false)
        XCTAssertEqual(dict["error"] as? String, "Invalid PIN")
    }

    func testAuthResultDecoding() throws {
        let json = """
        {"type":"auth_result","success":true,"error":null}
        """.data(using: .utf8)!

        let msg = try XCTUnwrap(MessageCoder.decode(AuthResultMessage.self, from: json))
        XCTAssertEqual(msg.type, "auth_result")
        XCTAssertTrue(msg.success)
        XCTAssertNil(msg.error)
    }

    func testAuthResultFailureDecoding() throws {
        let json = """
        {"type":"auth_result","success":false,"error":"Invalid PIN"}
        """.data(using: .utf8)!

        let msg = try XCTUnwrap(MessageCoder.decode(AuthResultMessage.self, from: json))
        XCTAssertFalse(msg.success)
        XCTAssertEqual(msg.error, "Invalid PIN")
    }

    // MARK: - Incoming messages (Mac → iPhone)

    func testLayoutUpdateDecoding() throws {
        let json = """
        {
            "type": "layout_update",
            "monitor": "Built-in Display",
            "windows": [
                {
                    "id": "w1",
                    "name": "Terminal",
                    "app": "Terminal",
                    "enabled": true,
                    "frame": { "x": 0.0, "y": 0.0, "width": 0.5, "height": 1.0 },
                    "state": "waiting_for_input",
                    "color": "#FF6B6B"
                },
                {
                    "id": "w2",
                    "name": "iTerm2",
                    "app": "iTerm2",
                    "enabled": false,
                    "frame": { "x": 0.5, "y": 0.0, "width": 0.5, "height": 1.0 },
                    "state": "neutral",
                    "color": "#4ECDC4"
                }
            ]
        }
        """.data(using: .utf8)!

        let update = try XCTUnwrap(MessageCoder.decode(LayoutUpdate.self, from: json))

        XCTAssertEqual(update.type, "layout_update")
        XCTAssertEqual(update.monitor, "Built-in Display")
        XCTAssertEqual(update.windows.count, 2)

        let w1 = update.windows[0]
        XCTAssertEqual(w1.id, "w1")
        XCTAssertEqual(w1.name, "Terminal")
        XCTAssertTrue(w1.enabled)
        XCTAssertEqual(w1.frame.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(w1.frame.width, 0.5, accuracy: 0.001)
        XCTAssertEqual(w1.state, "waiting_for_input")
        XCTAssertEqual(w1.color, "#FF6B6B")

        let w2 = update.windows[1]
        XCTAssertEqual(w2.id, "w2")
        XCTAssertFalse(w2.enabled)
        XCTAssertEqual(w2.frame.x, 0.5, accuracy: 0.001)
    }

    func testStateChangeMessageDecoding() throws {
        let json = """
        {"type":"state_change","windowId":"w1","state":"busy"}
        """.data(using: .utf8)!

        let msg = try XCTUnwrap(MessageCoder.decode(StateChangeMessage.self, from: json))
        XCTAssertEqual(msg.type, "state_change")
        XCTAssertEqual(msg.windowId, "w1")
        XCTAssertEqual(msg.state, "busy")
    }

    func testTerminalContentMessageDecoding() throws {
        let json = """
        {"type":"terminal_content","windowId":"w1","content":"$ ls\\nfoo bar\\n"}
        """.data(using: .utf8)!

        let msg = try XCTUnwrap(MessageCoder.decode(TerminalContentMessage.self, from: json))
        XCTAssertEqual(msg.type, "terminal_content")
        XCTAssertEqual(msg.windowId, "w1")
        XCTAssertEqual(msg.content, "$ ls\nfoo bar\n")
    }

    // MARK: - MessageCoder.messageType

    func testMessageTypeExtraction() throws {
        let cases: [(String, String)] = [
            (#"{"type":"layout_update","monitor":"M","windows":[]}"#, "layout_update"),
            (#"{"type":"state_change","windowId":"w1","state":"busy"}"#, "state_change"),
            (#"{"type":"terminal_content","windowId":"w1","content":"x"}"#, "terminal_content"),
            (#"{"type":"select_window","windowId":"w1"}"#, "select_window"),
            (#"{"type":"send_text","windowId":"w1","text":"hi","pressReturn":true}"#, "send_text"),
            (#"{"type":"quick_action","windowId":"w1","action":"press_return"}"#, "quick_action"),
            (#"{"type":"stt_started","windowId":"w1"}"#, "stt_started"),
            (#"{"type":"stt_ended","windowId":"w1"}"#, "stt_ended"),
            (#"{"type":"request_content","windowId":"w1"}"#, "request_content"),
            (#"{"type":"auth","pin":"123456"}"#, "auth"),
            (#"{"type":"auth_result","success":true,"error":null}"#, "auth_result"),
        ]

        for (json, expectedType) in cases {
            let data = json.data(using: .utf8)!
            let msgType = MessageCoder.messageType(from: data)
            XCTAssertEqual(msgType, expectedType, "Failed for: \(json)")
        }
    }

    func testUnknownMessageTypeDoesNotCrash() {
        let json = #"{"type":"future_message","data":123}"#.data(using: .utf8)!
        let msgType = MessageCoder.messageType(from: json)
        XCTAssertEqual(msgType, "future_message")
    }

    // MARK: - Round-trip tests

    func testSelectWindowRoundTrip() throws {
        let original = SelectWindowMessage(windowId: "round-trip-1")
        let data = try XCTUnwrap(MessageCoder.encode(original))
        let restored = try XCTUnwrap(MessageCoder.decode(SelectWindowMessage.self, from: data))
        XCTAssertEqual(original.windowId, restored.windowId)
        XCTAssertEqual(original.type, restored.type)
    }

    func testSendTextRoundTrip() throws {
        let original = SendTextMessage(windowId: "rt-2", text: "Hello, Quip!")
        let data = try XCTUnwrap(MessageCoder.encode(original))
        let restored = try XCTUnwrap(MessageCoder.decode(SendTextMessage.self, from: data))
        XCTAssertEqual(original.windowId, restored.windowId)
        XCTAssertEqual(original.text, restored.text)
        XCTAssertEqual(original.pressReturn, restored.pressReturn)
    }

    func testQuickActionRoundTrip() throws {
        let original = QuickActionMessage(windowId: "rt-3", action: "clear_terminal")
        let data = try XCTUnwrap(MessageCoder.encode(original))
        let restored = try XCTUnwrap(MessageCoder.decode(QuickActionMessage.self, from: data))
        XCTAssertEqual(original.windowId, restored.windowId)
        XCTAssertEqual(original.action, restored.action)
    }

    func testLayoutUpdateRoundTrip() throws {
        let original = LayoutUpdate(
            monitor: "Test Monitor",
            windows: [
                WindowState(
                    id: "w1", name: "zsh", app: "Terminal",
                    enabled: true,
                    frame: WindowFrame(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                    state: "neutral", color: "#AABBCC"
                )
            ]
        )
        let data = try XCTUnwrap(MessageCoder.encode(original))
        let restored = try XCTUnwrap(MessageCoder.decode(LayoutUpdate.self, from: data))
        XCTAssertEqual(original.monitor, restored.monitor)
        XCTAssertEqual(original.windows.count, restored.windows.count)
        XCTAssertEqual(original.windows[0].id, restored.windows[0].id)
        XCTAssertEqual(original.windows[0].frame.x, restored.windows[0].frame.x, accuracy: 0.001)
    }

    // MARK: - Edge cases

    func testSendTextEmptyText() throws {
        let msg = SendTextMessage(windowId: "w1", text: "")
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let restored = try XCTUnwrap(MessageCoder.decode(SendTextMessage.self, from: data))
        XCTAssertEqual(restored.text, "")
    }

    func testSendTextSpecialCharacters() throws {
        let text = #"echo "hello" && ls -la | grep 'foo'"#
        let msg = SendTextMessage(windowId: "w1", text: text)
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let restored = try XCTUnwrap(MessageCoder.decode(SendTextMessage.self, from: data))
        XCTAssertEqual(restored.text, text)
    }

    func testTerminalContentMultiline() throws {
        let content = "line1\nline2\nline3\n\ttabbed"
        let msg = TerminalContentMessage(windowId: "w1", content: content)
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let restored = try XCTUnwrap(MessageCoder.decode(TerminalContentMessage.self, from: data))
        XCTAssertEqual(restored.content, content)
    }

    func testLayoutUpdateEmptyWindows() throws {
        let json = #"{"type":"layout_update","monitor":"M","windows":[]}"#.data(using: .utf8)!
        let update = try XCTUnwrap(MessageCoder.decode(LayoutUpdate.self, from: json))
        XCTAssertEqual(update.windows.count, 0)
    }

    func testWindowFramePrecision() throws {
        let frame = WindowFrame(x: 0.123456, y: 0.654321, width: 0.5, height: 0.5)
        let data = try JSONEncoder().encode(frame)
        let restored = try JSONDecoder().decode(WindowFrame.self, from: data)
        XCTAssertEqual(frame.x, restored.x, accuracy: 1e-10)
        XCTAssertEqual(frame.y, restored.y, accuracy: 1e-10)
    }

    // MARK: - Cross-platform JSON key compatibility

    func testSortedKeysEncoding() throws {
        // MessageCoder uses .sortedKeys — verify keys are alphabetically ordered
        let msg = SendTextMessage(windowId: "w1", text: "test")
        let data = try XCTUnwrap(MessageCoder.encode(msg))
        let jsonString = String(data: data, encoding: .utf8)!

        // With sorted keys, "pressReturn" comes before "text", "text" before "type", etc.
        let pressReturnIndex = jsonString.range(of: "pressReturn")!.lowerBound
        let textIndex = jsonString.range(of: "\"text\"")!.lowerBound
        let typeIndex = jsonString.range(of: "\"type\"")!.lowerBound

        XCTAssertTrue(pressReturnIndex < textIndex)
        XCTAssertTrue(textIndex < typeIndex)
    }

    // MARK: - Helpers

    private func jsonDict(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
