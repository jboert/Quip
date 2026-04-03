package dev.quip.android.models

import com.google.gson.Gson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for message encoding/decoding.
 * Verifies that all protocol message types serialize to the expected JSON
 * and can be deserialized back correctly, ensuring cross-platform compatibility
 * with the Swift MessageProtocol.
 */
class ProtocolTest {

    private val gson = Gson()

    // -- Outgoing messages (Android → Mac) --

    @Test
    fun `SelectWindowMessage serializes with correct type`() {
        val msg = SelectWindowMessage(windowId = "win-123")
        val json = gson.toJson(msg)
        val map = gson.fromJson(json, Map::class.java)

        assertEquals("select_window", map["type"])
        assertEquals("win-123", map["windowId"])
    }

    @Test
    fun `SendTextMessage serializes with pressReturn default true`() {
        val msg = SendTextMessage(windowId = "win-1", text = "hello world")
        val json = gson.toJson(msg)
        val map = gson.fromJson(json, Map::class.java)

        assertEquals("send_text", map["type"])
        assertEquals("win-1", map["windowId"])
        assertEquals("hello world", map["text"])
        assertEquals(true, map["pressReturn"])
    }

    @Test
    fun `SendTextMessage serializes with pressReturn false`() {
        val msg = SendTextMessage(windowId = "win-1", text = "hi", pressReturn = false)
        val json = gson.toJson(msg)
        val map = gson.fromJson(json, Map::class.java)

        assertEquals(false, map["pressReturn"])
    }

    @Test
    fun `QuickActionMessage serializes correctly`() {
        val msg = QuickActionMessage(windowId = "win-2", action = "press_ctrl_c")
        val json = gson.toJson(msg)
        val map = gson.fromJson(json, Map::class.java)

        assertEquals("quick_action", map["type"])
        assertEquals("win-2", map["windowId"])
        assertEquals("press_ctrl_c", map["action"])
    }

    @Test
    fun `SttStateMessage started serializes correctly`() {
        val msg = SttStateMessage.started("win-5")
        val json = gson.toJson(msg)
        val map = gson.fromJson(json, Map::class.java)

        assertEquals("stt_started", map["type"])
        assertEquals("win-5", map["windowId"])
    }

    @Test
    fun `SttStateMessage ended serializes correctly`() {
        val msg = SttStateMessage.ended("win-5")
        val json = gson.toJson(msg)
        val map = gson.fromJson(json, Map::class.java)

        assertEquals("stt_ended", map["type"])
        assertEquals("win-5", map["windowId"])
    }

    @Test
    fun `RequestContentMessage serializes correctly`() {
        val msg = RequestContentMessage(windowId = "win-3")
        val json = gson.toJson(msg)
        val map = gson.fromJson(json, Map::class.java)

        assertEquals("request_content", map["type"])
        assertEquals("win-3", map["windowId"])
    }

    // -- Incoming messages (Mac → Android) --

    @Test
    fun `LayoutUpdate deserializes correctly`() {
        val json = """
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
        """.trimIndent()

        val update = gson.fromJson(json, LayoutUpdate::class.java)

        assertEquals("layout_update", update.type)
        assertEquals("Built-in Display", update.monitor)
        assertEquals(2, update.windows.size)

        val w1 = update.windows[0]
        assertEquals("w1", w1.id)
        assertEquals("Terminal", w1.name)
        assertEquals("Terminal", w1.app)
        assertTrue(w1.enabled)
        assertEquals(0.0, w1.frame.x, 0.001)
        assertEquals(0.5, w1.frame.width, 0.001)
        assertEquals("waiting_for_input", w1.state)
        assertEquals("#FF6B6B", w1.color)

        val w2 = update.windows[1]
        assertEquals("w2", w2.id)
        assertEquals(false, w2.enabled)
        assertEquals(0.5, w2.frame.x, 0.001)
    }

    @Test
    fun `StateChangeMessage deserializes correctly`() {
        val json = """{"type":"state_change","windowId":"w1","state":"busy"}"""
        val msg = gson.fromJson(json, StateChangeMessage::class.java)

        assertEquals("state_change", msg.type)
        assertEquals("w1", msg.windowId)
        assertEquals("busy", msg.state)
    }

    @Test
    fun `TerminalContentMessage deserializes correctly`() {
        val json = """{"type":"terminal_content","windowId":"w1","content":"$ ls\nfoo bar\n"}"""
        val msg = gson.fromJson(json, TerminalContentMessage::class.java)

        assertEquals("terminal_content", msg.type)
        assertEquals("w1", msg.windowId)
        assertEquals("$ ls\nfoo bar\n", msg.content)
    }

    // -- Envelope / type peeking --

    @Test
    fun `MessageEnvelope extracts type from any message`() {
        val messages = listOf(
            """{"type":"layout_update","monitor":"M","windows":[]}""",
            """{"type":"state_change","windowId":"w1","state":"busy"}""",
            """{"type":"terminal_content","windowId":"w1","content":"x"}""",
            """{"type":"select_window","windowId":"w1"}""",
            """{"type":"send_text","windowId":"w1","text":"hi","pressReturn":true}""",
            """{"type":"quick_action","windowId":"w1","action":"press_return"}""",
            """{"type":"stt_started","windowId":"w1"}""",
            """{"type":"stt_ended","windowId":"w1"}""",
            """{"type":"request_content","windowId":"w1"}"""
        )

        val expectedTypes = listOf(
            "layout_update", "state_change", "terminal_content",
            "select_window", "send_text", "quick_action",
            "stt_started", "stt_ended", "request_content"
        )

        messages.zip(expectedTypes).forEach { (json, expectedType) ->
            val envelope = gson.fromJson(json, MessageEnvelope::class.java)
            assertNotNull("Failed to parse: $json", envelope)
            assertEquals(expectedType, envelope.type)
        }
    }

    @Test
    fun `unknown message type does not crash envelope parsing`() {
        val json = """{"type":"future_message","data":123}"""
        val envelope = gson.fromJson(json, MessageEnvelope::class.java)
        assertEquals("future_message", envelope.type)
    }

    // -- Round-trip tests --

    @Test
    fun `SelectWindowMessage survives round-trip`() {
        val original = SelectWindowMessage(windowId = "round-trip-1")
        val json = gson.toJson(original)
        val restored = gson.fromJson(json, SelectWindowMessage::class.java)
        assertEquals(original, restored)
    }

    @Test
    fun `SendTextMessage survives round-trip`() {
        val original = SendTextMessage(windowId = "rt-2", text = "Hello, Quip!")
        val json = gson.toJson(original)
        val restored = gson.fromJson(json, SendTextMessage::class.java)
        assertEquals(original, restored)
    }

    @Test
    fun `QuickActionMessage survives round-trip`() {
        val original = QuickActionMessage(windowId = "rt-3", action = "clear_terminal")
        val json = gson.toJson(original)
        val restored = gson.fromJson(json, QuickActionMessage::class.java)
        assertEquals(original, restored)
    }

    @Test
    fun `LayoutUpdate survives round-trip`() {
        val original = LayoutUpdate(
            monitor = "Test Monitor",
            windows = listOf(
                WindowState(
                    id = "w1", name = "zsh", app = "Terminal",
                    enabled = true,
                    frame = WindowFrame(x = 0.1, y = 0.2, width = 0.3, height = 0.4),
                    state = "neutral", color = "#AABBCC"
                )
            )
        )
        val json = gson.toJson(original)
        val restored = gson.fromJson(json, LayoutUpdate::class.java)
        assertEquals(original.type, restored.type)
        assertEquals(original.monitor, restored.monitor)
        assertEquals(original.windows.size, restored.windows.size)
        assertEquals(original.windows[0].id, restored.windows[0].id)
        assertEquals(original.windows[0].frame.x, restored.windows[0].frame.x, 0.001)
    }

    // -- Edge cases --

    @Test
    fun `SendTextMessage handles empty text`() {
        val msg = SendTextMessage(windowId = "w1", text = "")
        val json = gson.toJson(msg)
        val restored = gson.fromJson(json, SendTextMessage::class.java)
        assertEquals("", restored.text)
    }

    @Test
    fun `SendTextMessage handles special characters`() {
        val msg = SendTextMessage(windowId = "w1", text = "echo \"hello\" && ls -la | grep 'foo'")
        val json = gson.toJson(msg)
        val restored = gson.fromJson(json, SendTextMessage::class.java)
        assertEquals("echo \"hello\" && ls -la | grep 'foo'", restored.text)
    }

    @Test
    fun `TerminalContentMessage handles multiline content`() {
        val content = "line1\nline2\nline3\n\ttabbed"
        val json = gson.toJson(TerminalContentMessage(windowId = "w1", content = content))
        val restored = gson.fromJson(json, TerminalContentMessage::class.java)
        assertEquals(content, restored.content)
    }

    @Test
    fun `LayoutUpdate handles empty window list`() {
        val json = """{"type":"layout_update","monitor":"M","windows":[]}"""
        val update = gson.fromJson(json, LayoutUpdate::class.java)
        assertEquals(0, update.windows.size)
    }

    @Test
    fun `WindowFrame normalized coordinates preserved`() {
        val frame = WindowFrame(x = 0.123456, y = 0.654321, width = 0.5, height = 0.5)
        val json = gson.toJson(frame)
        val restored = gson.fromJson(json, WindowFrame::class.java)
        assertEquals(frame.x, restored.x, 1e-10)
        assertEquals(frame.y, restored.y, 1e-10)
    }
}
