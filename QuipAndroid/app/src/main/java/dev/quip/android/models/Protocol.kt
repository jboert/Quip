package dev.quip.android.models

import com.google.gson.annotations.SerializedName

// MARK: - Mac → Android Messages

data class WindowFrame(
    val x: Double,
    val y: Double,
    val width: Double,
    val height: Double
)

data class WindowState(
    val id: String,
    val name: String,
    val app: String,
    val enabled: Boolean,
    val frame: WindowFrame,
    val state: String,
    val color: String
)

data class LayoutUpdate(
    val type: String = "layout_update",
    val monitor: String,
    val windows: List<WindowState>
)

data class StateChangeMessage(
    val type: String = "state_change",
    @SerializedName("windowId") val windowId: String,
    val state: String
)

// MARK: - Android → Mac Messages

data class SelectWindowMessage(
    val type: String = "select_window",
    @SerializedName("windowId") val windowId: String
)

data class SendTextMessage(
    val type: String = "send_text",
    @SerializedName("windowId") val windowId: String,
    val text: String,
    @SerializedName("pressReturn") val pressReturn: Boolean = true
)

data class QuickActionMessage(
    val type: String = "quick_action",
    @SerializedName("windowId") val windowId: String,
    val action: String
)

data class SttStateMessage(
    val type: String,
    @SerializedName("windowId") val windowId: String
) {
    companion object {
        fun started(windowId: String) = SttStateMessage(type = "stt_started", windowId = windowId)
        fun ended(windowId: String) = SttStateMessage(type = "stt_ended", windowId = windowId)
    }
}

data class RequestContentMessage(
    val type: String = "request_content",
    @SerializedName("windowId") val windowId: String
)

data class TerminalContentMessage(
    val type: String = "terminal_content",
    @SerializedName("windowId") val windowId: String,
    val content: String,
    val screenshot: String? = null
)

// MARK: - Message Envelope (for peeking at type before full deserialization)

data class MessageEnvelope(val type: String)
