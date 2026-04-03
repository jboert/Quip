package dev.quip.android

import android.content.pm.ActivityInfo
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dev.quip.android.models.QuickActionMessage
import dev.quip.android.models.SelectWindowMessage
import dev.quip.android.models.SendTextMessage
import dev.quip.android.models.SttStateMessage
import dev.quip.android.models.WindowState
import dev.quip.android.models.SavedConnection
import dev.quip.android.services.ConnectionManager
import dev.quip.android.services.DiscoveredHost
import dev.quip.android.services.NsdBrowser
import dev.quip.android.services.QuipWebSocketClient
import dev.quip.android.services.SpeechService
import dev.quip.android.ui.screens.MainScreen
import dev.quip.android.ui.theme.QuipTheme

class MainActivity : ComponentActivity() {

    companion object {
        private const val TAG = "Quip"
        private const val PREFS_NAME = "quip_prefs"
        private const val KEY_LAST_URL = "last_url"
        private const val STOP_RECORDING_DELAY_MS = 800L
    }

    // State
    private var windows = mutableStateListOf<WindowState>()
    private var selectedWindowId by mutableStateOf<String?>(null)
    private var isConnected by mutableStateOf(false)
    private var isConnecting by mutableStateOf(false)
    private var isRecording by mutableStateOf(false)
    private var monitorName by mutableStateOf("Mac")
    private var urlText by mutableStateOf("")
    private var discoveredHosts = mutableStateListOf<DiscoveredHost>()
    private var recentConnections = mutableStateListOf<SavedConnection>()

    // Services
    private val webSocketClient = QuipWebSocketClient()
    private val speechService = SpeechService()
    private val nsdBrowser = NsdBrowser()
    private val handler = Handler(Looper.getMainLooper())

    private var hasReceivedLayout = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT

        // Load persisted state
        recentConnections.addAll(ConnectionManager.loadRecents(this))
        val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        urlText = prefs.getString(KEY_LAST_URL, "") ?: ""

        // Wire up WebSocket callbacks
        webSocketClient.onLayoutUpdate = { update ->
            val wasEmpty = windows.isEmpty()
            windows.clear()
            windows.addAll(update.windows)
            monitorName = update.monitor

            // Switch to landscape on first layout
            if (!hasReceivedLayout && update.windows.isNotEmpty()) {
                hasReceivedLayout = true
                requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            }

            // Auto-select first window if none selected
            if (selectedWindowId == null && windows.isNotEmpty()) {
                selectedWindowId = windows.first().id
            }
        }

        webSocketClient.onStateChange = { windowId, newState ->
            val index = windows.indexOfFirst { it.id == windowId }
            if (index >= 0) {
                val w = windows[index]
                windows[index] = w.copy(state = newState)
            }
        }

        webSocketClient.onConnectionStateChanged = {
            isConnected = webSocketClient.isConnected
            isConnecting = webSocketClient.isConnecting

            if (!isConnected && !isConnecting) {
                windows.clear()
                selectedWindowId = null
                hasReceivedLayout = false
                requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            }
        }

        // Wire up NSD callbacks
        nsdBrowser.onHostsChanged = {
            discoveredHosts.clear()
            discoveredHosts.addAll(nsdBrowser.discoveredHosts)
        }
        nsdBrowser.startDiscovery(this)

        setContent {
            QuipTheme {
                MainScreen(
                    isConnected = isConnected,
                    isConnecting = isConnecting,
                    isRecording = isRecording,
                    windows = windows.toList(),
                    selectedWindowId = selectedWindowId,
                    monitorName = monitorName,
                    urlText = urlText,
                    onUrlChange = { urlText = it },
                    onConnect = { url -> doConnect(url) },
                    onDisconnect = { doDisconnect() },
                    discoveredHosts = discoveredHosts.toList(),
                    recentConnections = recentConnections.toList(),
                    onPinToggle = { conn -> togglePin(conn) },
                    onRename = { conn, name -> renameConnection(conn, name) },
                    onDelete = { conn -> deleteConnection(conn) },
                    onScanQR = { /* QR scanning to be wired via CameraX + MLKit */ },
                    onSelectWindow = { windowId ->
                        selectedWindowId = windowId
                        webSocketClient.send(SelectWindowMessage(windowId = windowId))
                    },
                    onWindowAction = { windowId, action ->
                        webSocketClient.send(QuickActionMessage(windowId = windowId, action = action))
                    },
                    onStopRecording = { stopRecording() }
                )
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        webSocketClient.disconnect()
        nsdBrowser.stopDiscovery()
        speechService.destroy()
    }

    // -- Volume button handling --

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_DOWN -> {
                if (!isRecording) {
                    startRecording()
                } else {
                    stopRecording()
                }
                return true
            }
            KeyEvent.KEYCODE_VOLUME_UP -> {
                if (!isRecording) {
                    cycleSelectedWindow()
                } else {
                    stopRecording()
                }
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            return true // consume to prevent system volume change
        }
        return super.onKeyUp(keyCode, event)
    }

    // -- Recording --

    private fun startRecording() {
        val windowId = selectedWindowId ?: return
        speechService.startRecording(this)
        isRecording = true
        webSocketClient.send(SttStateMessage.started(windowId))
        Log.d(TAG, "Recording started for window $windowId")
    }

    private fun stopRecording() {
        if (!isRecording) return
        val windowId = selectedWindowId
        Log.d(TAG, "stopRecording called, windowId=$windowId")

        handler.postDelayed({
            val text = speechService.stopRecording()
            isRecording = false
            Log.d(TAG, "Transcribed: '$text' (length=${text.length})")

            if (windowId != null) {
                webSocketClient.send(SttStateMessage.ended(windowId))
                if (text.isNotEmpty()) {
                    Log.d(TAG, "Sending text to window $windowId")
                    webSocketClient.send(SendTextMessage(windowId = windowId, text = text))
                }
            }
        }, STOP_RECORDING_DELAY_MS)
    }

    private fun cycleSelectedWindow() {
        if (windows.isEmpty()) return
        val currentIndex = windows.indexOfFirst { it.id == selectedWindowId }
        val nextIndex = if (currentIndex < 0) 0 else (currentIndex + 1) % windows.size
        selectedWindowId = windows[nextIndex].id
        webSocketClient.send(SelectWindowMessage(windowId = windows[nextIndex].id))
    }

    // -- WebSocket connection --

    private fun doConnect(url: String) {
        if (url.isBlank()) return

        val wsUrl = when {
            url.startsWith("wss://") || url.startsWith("ws://") -> url
            url.contains("trycloudflare.com") -> "wss://$url"
            url.contains(":") -> "ws://$url"
            else -> "wss://$url"
        }

        urlText = url
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            .edit().putString(KEY_LAST_URL, url).apply()

        ConnectionManager.saveRecent(this, wsUrl)
        recentConnections.clear()
        recentConnections.addAll(ConnectionManager.loadRecents(this))

        hasReceivedLayout = false
        webSocketClient.connect(wsUrl)
    }

    private fun doDisconnect() {
        webSocketClient.disconnect()
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
    }

    // -- Recent Connections management --

    private fun togglePin(conn: SavedConnection) {
        ConnectionManager.togglePin(this, conn.id)
        recentConnections.clear()
        recentConnections.addAll(ConnectionManager.loadRecents(this))
    }

    private fun renameConnection(conn: SavedConnection, name: String) {
        ConnectionManager.rename(this, conn.id, name)
        recentConnections.clear()
        recentConnections.addAll(ConnectionManager.loadRecents(this))
    }

    private fun deleteConnection(conn: SavedConnection) {
        ConnectionManager.delete(this, conn.id)
        recentConnections.clear()
        recentConnections.addAll(ConnectionManager.loadRecents(this))
    }
}
