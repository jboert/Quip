package dev.quip.android

import android.app.Application
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.ActivityInfo
import android.os.VibrationEffect
import android.os.VibratorManager
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import dev.quip.android.models.QuickActionMessage
import dev.quip.android.models.RequestContentMessage
import dev.quip.android.models.SelectWindowMessage
import dev.quip.android.models.SendTextMessage
import dev.quip.android.models.SttStateMessage
import dev.quip.android.models.WindowState
import dev.quip.android.models.SavedConnection
import dev.quip.android.services.ConnectionManager
import dev.quip.android.services.ConnectionService
import dev.quip.android.services.DiscoveredHost
import dev.quip.android.services.NetworkValidator
import dev.quip.android.services.NsdBrowser
import dev.quip.android.services.QuipWebSocketClient
import dev.quip.android.services.SpeechService
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class MainViewModel(application: Application) : AndroidViewModel(application) {

    companion object {
        private const val TAG = "Quip"
        private const val PREFS_NAME = "quip_prefs"
        private const val KEY_LAST_URL = "last_url"
        private const val STOP_RECORDING_DELAY_MS = 2500L  // extra recording after button release for conversational pauses
        private const val RESULT_TIMEOUT_MS = 1500L
    }

    // Recording state machine
    sealed class RecordingState {
        object Idle : RecordingState()
        data class Recording(val windowId: String) : RecordingState()
        data class WaitingForResult(val windowId: String) : RecordingState()
    }

    // UI state
    var windows = mutableStateListOf<WindowState>()
        private set
    var selectedWindowId by mutableStateOf<String?>(null)
        private set
    var isConnected by mutableStateOf(false)
        private set
    var isConnecting by mutableStateOf(false)
        private set
    var recordingState by mutableStateOf<RecordingState>(RecordingState.Idle)
        private set
    val isRecording: Boolean get() = recordingState !is RecordingState.Idle
    var monitorName by mutableStateOf("Mac")
        private set
    var urlText by mutableStateOf("")
    var discoveredHosts = mutableStateListOf<DiscoveredHost>()
        private set
    var recentConnections = mutableStateListOf<SavedConnection>()
        private set
    var showQrScanner by mutableStateOf(false)
    var terminalContentText by mutableStateOf<String?>(null)
        private set
    var terminalContentScreenshot by mutableStateOf<String?>(null)
        private set
    var terminalContentWindowId by mutableStateOf<String?>(null)
        private set
    var isAuthenticated by mutableStateOf(false)
        private set
    var authError by mutableStateOf<String?>(null)
        private set
    var showPinEntry by mutableStateOf(false)
        private set
    var pinText by mutableStateOf("")
    var showTextInput by mutableStateOf(false)
    var textInputValue by mutableStateOf("")
    var showUrlWarning by mutableStateOf(false)
        private set
    var pendingUnsafeUrl by mutableStateOf<String?>(null)
        private set

    // Orientation request callback — set by Activity
    var onRequestOrientation: ((Int) -> Unit)? = null

    // Services
    val webSocketClient = QuipWebSocketClient()
    val speechService = SpeechService()
    val nsdBrowser = NsdBrowser()

    private var hasReceivedLayout = false
    private var hasSentTranscription = false
    private var stopRecordingJob: Job? = null

    fun initialize() {
        val context = getApplication<Application>()

        recentConnections.addAll(ConnectionManager.loadRecents(context))
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        urlText = prefs.getString(KEY_LAST_URL, "") ?: ""

        speechService.initModel(context)
        wireCallbacks()
        nsdBrowser.startDiscovery(context)
    }

    private fun wireCallbacks() {
        webSocketClient.onLayoutUpdate = { update ->
            windows.clear()
            windows.addAll(update.windows)
            monitorName = update.monitor

            if (!hasReceivedLayout && update.windows.isNotEmpty() && webSocketClient.isAuthenticated) {
                hasReceivedLayout = true
                onRequestOrientation?.invoke(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE)
            }

            if (selectedWindowId == null && windows.isNotEmpty()) {
                selectedWindowId = windows.first().id
            }
        }

        webSocketClient.onStateChange = { windowId, newState ->
            val index = windows.indexOfFirst { it.id == windowId }
            if (index >= 0) {
                windows[index] = windows[index].copy(state = newState)
            }
        }

        webSocketClient.onConnectionStateChanged = {
            val context = getApplication<Application>()
            val wasConnected = isConnected
            isConnected = webSocketClient.isConnected
            isConnecting = webSocketClient.isConnecting
            isAuthenticated = webSocketClient.isAuthenticated
            authError = webSocketClient.authError

            if (isConnected && !wasConnected) {
                ConnectionService.start(context, monitorName)
            } else if (!isConnected && !isConnecting) {
                ConnectionService.stop(context)
                windows.clear()
                selectedWindowId = null
                hasReceivedLayout = false
                showPinEntry = false
                pinText = ""
                authError = null
                onRequestOrientation?.invoke(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT)
            }
        }

        webSocketClient.onAuthRequired = {
            showPinEntry = true
            pinText = ""
            authError = null
        }

        webSocketClient.onAuthResult = { success, error ->
            if (success) {
                showPinEntry = false
                pinText = ""
                authError = null
            } else {
                authError = error ?: "Authentication failed"
                pinText = ""
            }
        }

        webSocketClient.onTerminalContent = { windowId, content, screenshot ->
            terminalContentWindowId = windowId
            terminalContentText = content
            terminalContentScreenshot = screenshot
        }

        nsdBrowser.onHostsChanged = {
            discoveredHosts.clear()
            discoveredHosts.addAll(nsdBrowser.discoveredHosts)
        }
    }

    // -- Recording state machine --

    fun startRecording(context: Context) {
        if (recordingState !is RecordingState.Idle) return
        val windowId = selectedWindowId ?: return

        speechService.onFinalResult = { text ->
            Log.d(TAG, "Final transcription: '$text' (length=${text.length})")
            val state = recordingState
            if (state is RecordingState.WaitingForResult) {
                stopRecordingJob?.cancel()
                sendTranscription(state.windowId, text)
            }
            // If still Recording, stopRecording will pick up transcribedText
        }

        speechService.onError = { error ->
            Log.w(TAG, "Speech error: $error")
            val state = recordingState
            if (state is RecordingState.WaitingForResult) {
                stopRecordingJob?.cancel()
                sendTranscription(state.windowId, speechService.transcribedText)
            }
        }

        hasSentTranscription = false
        speechService.startRecording(context)
        recordingState = RecordingState.Recording(windowId)
        performHaptic(VibrationEffect.EFFECT_HEAVY_CLICK)
        webSocketClient.send(SttStateMessage.started(windowId))
        Log.d(TAG, "Recording started for window $windowId")
    }

    fun stopRecording() {
        val state = recordingState
        if (state !is RecordingState.Recording) return

        val windowId = state.windowId
        recordingState = RecordingState.WaitingForResult(windowId)
        Log.d(TAG, "stopRecording called, windowId=$windowId")

        // Haptic: triple heavy tap for recording stop
        performHaptic(VibrationEffect.EFFECT_HEAVY_CLICK)
        viewModelScope.launch {
            delay(100)
            performHaptic(VibrationEffect.EFFECT_HEAVY_CLICK)
            delay(100)
            performHaptic(VibrationEffect.EFFECT_HEAVY_CLICK)
        }

        // If the recognizer already delivered a final result, send it now
        if (!speechService.isRecording && speechService.transcribedText.isNotEmpty()) {
            sendTranscription(windowId, speechService.transcribedText)
            return
        }

        // Coroutine-based stop: wait for audio, then request stop, then fallback timeout
        stopRecordingJob = viewModelScope.launch {
            delay(STOP_RECORDING_DELAY_MS)
            speechService.requestStop()

            delay(RESULT_TIMEOUT_MS)
            // If still waiting, send what we have
            if (recordingState is RecordingState.WaitingForResult) {
                val text = speechService.transcribedText
                if (text.isNotEmpty()) {
                    Log.d(TAG, "Fallback: sending partial text '$text'")
                    sendTranscription(windowId, text)
                } else {
                    webSocketClient.send(SttStateMessage.ended(windowId))
                    recordingState = RecordingState.Idle
                }
            }
        }
    }

    private fun sendTranscription(windowId: String, text: String) {
        if (hasSentTranscription) return
        hasSentTranscription = true
        recordingState = RecordingState.Idle
        webSocketClient.send(SttStateMessage.ended(windowId))
        if (text.isNotEmpty()) {
            Log.d(TAG, "Sending text to window $windowId: '$text'")
            webSocketClient.send(SendTextMessage(windowId = windowId, text = text))
        }
    }

    // -- Window actions --

    fun selectWindow(windowId: String) {
        selectedWindowId = windowId
        webSocketClient.send(SelectWindowMessage(windowId = windowId))
    }

    fun handleWindowAction(windowId: String, action: String) {
        if (action == "view_output") {
            webSocketClient.send(RequestContentMessage(windowId = windowId))
        } else {
            webSocketClient.send(QuickActionMessage(windowId = windowId, action = action))
        }
    }

    fun cycleSelectedWindow() {
        if (windows.isEmpty()) return
        val currentIndex = windows.indexOfFirst { it.id == selectedWindowId }
        val nextIndex = if (currentIndex < 0) 0 else (currentIndex + 1) % windows.size
        val newId = windows[nextIndex].id
        selectedWindowId = newId
        webSocketClient.send(SelectWindowMessage(windowId = newId))
        if (terminalContentText != null) {
            terminalContentWindowId = newId
            webSocketClient.send(RequestContentMessage(windowId = newId))
        }
    }

    // -- Connection --

    fun connect(url: String) {
        if (url.isBlank()) return

        val wsUrl = when {
            url.startsWith("wss://") || url.startsWith("ws://") -> url
            url.contains("trycloudflare.com") -> "wss://$url"
            url.contains(":") -> "ws://$url"
            else -> "wss://$url"
        }

        // Validate: cleartext (ws://) only allowed for private/local networks
        if (!NetworkValidator.isSafeUrl(wsUrl)) {
            Log.w(TAG, "Rejected connection to non-private network via cleartext: $wsUrl")
            return
        }

        // Warn about unrecognized URLs (not local network or Cloudflare tunnel)
        if (!NetworkValidator.isURLTrusted(wsUrl)) {
            pendingUnsafeUrl = wsUrl
            showUrlWarning = true
            return
        }

        doConnect(wsUrl)
    }

    fun connectAnyway() {
        val url = pendingUnsafeUrl ?: return
        showUrlWarning = false
        pendingUnsafeUrl = null
        doConnect(url)
    }

    fun dismissUrlWarning() {
        showUrlWarning = false
        pendingUnsafeUrl = null
    }

    private fun doConnect(wsUrl: String) {
        val context = getApplication<Application>()

        urlText = wsUrl
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit().putString(KEY_LAST_URL, wsUrl).apply()

        ConnectionManager.saveRecent(context, wsUrl)
        recentConnections.clear()
        recentConnections.addAll(ConnectionManager.loadRecents(context))

        hasReceivedLayout = false
        webSocketClient.connect(wsUrl)
    }

    fun disconnect() {
        webSocketClient.disconnect()
        showPinEntry = false
        pinText = ""
        authError = null
        onRequestOrientation?.invoke(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT)
    }

    fun sendAuth() {
        val pin = pinText.trim()
        if (pin.length < 4) return
        webSocketClient.sendAuth(pin)
    }

    // -- Recent connections --

    fun togglePin(conn: SavedConnection) {
        val context = getApplication<Application>()
        ConnectionManager.togglePin(context, conn.id)
        recentConnections.clear()
        recentConnections.addAll(ConnectionManager.loadRecents(context))
    }

    fun renameConnection(conn: SavedConnection, name: String) {
        val context = getApplication<Application>()
        ConnectionManager.rename(context, conn.id, name)
        recentConnections.clear()
        recentConnections.addAll(ConnectionManager.loadRecents(context))
    }

    fun deleteConnection(conn: SavedConnection) {
        val context = getApplication<Application>()
        ConnectionManager.delete(context, conn.id)
        recentConnections.clear()
        recentConnections.addAll(ConnectionManager.loadRecents(context))
    }

    // -- Clipboard --

    fun pasteFromClipboard() {
        val context = getApplication<Application>()
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = clipboard.primaryClip
        if (clip != null && clip.itemCount > 0) {
            val text = clip.getItemAt(0).coerceToText(context).toString().trim()
            if (text.isNotEmpty()) {
                urlText = text
            }
        }
    }

    // -- Terminal content --

    fun dismissTerminalContent() {
        terminalContentText = null
        terminalContentScreenshot = null
        terminalContentWindowId = null
    }

    fun sendTerminalAction(action: String) {
        terminalContentWindowId?.let { wid ->
            webSocketClient.send(QuickActionMessage(windowId = wid, action = action))
        }
    }

    fun sendTextInput() {
        val text = textInputValue.trim()
        val windowId = selectedWindowId ?: return
        if (text.isEmpty()) return
        webSocketClient.send(SendTextMessage(windowId = windowId, text = text))
        textInputValue = ""
    }

    fun refreshTerminalContent() {
        terminalContentWindowId?.let { wid ->
            webSocketClient.send(RequestContentMessage(windowId = wid))
        }
    }

    val terminalContentWindowName: String
        get() = windows.firstOrNull { it.id == terminalContentWindowId }?.name ?: "Terminal"

    // -- Haptics --

    private fun performHaptic(effectId: Int) {
        try {
            val context = getApplication<Application>()
            val vibrator = (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
            vibrator.vibrate(VibrationEffect.createPredefined(effectId))
        } catch (e: Exception) {
            Log.w(TAG, "Haptic feedback failed: ${e.message}")
        }
    }

    // -- Cleanup --

    override fun onCleared() {
        super.onCleared()
        ConnectionService.stop(getApplication())
        webSocketClient.disconnect()
        nsdBrowser.stopDiscovery()
        speechService.destroy()
    }
}
