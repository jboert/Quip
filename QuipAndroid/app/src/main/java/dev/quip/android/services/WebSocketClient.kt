package dev.quip.android.services

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.gson.Gson
import dev.quip.android.models.LayoutUpdate
import dev.quip.android.models.MessageEnvelope
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit

class QuipWebSocketClient {

    companion object {
        private const val TAG = "QuipWebSocketClient"
        private const val INITIAL_RECONNECT_DELAY_MS = 1000L
        private const val MAX_RECONNECT_DELAY_MS = 10000L
    }

    @Volatile var isConnected: Boolean = false
        private set
    @Volatile var isConnecting: Boolean = false
        private set
    @Volatile var lastError: String? = null
        private set

    var onLayoutUpdate: ((LayoutUpdate) -> Unit)? = null
    var onStateChange: ((windowId: String, state: String) -> Unit)? = null
    var onConnectionStateChanged: (() -> Unit)? = null

    private val gson = Gson()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var webSocket: WebSocket? = null
    private var client: OkHttpClient? = null
    private var serverUrl: String? = null
    private var intentionalDisconnect = false
    private var reconnectDelay = INITIAL_RECONNECT_DELAY_MS
    private val reconnectHandler = Handler(Looper.getMainLooper())
    private var reconnectRunnable: Runnable? = null

    private val lock = Any()

    fun connect(url: String) {
        synchronized(lock) {
            intentionalDisconnect = false
            serverUrl = url
            reconnectDelay = INITIAL_RECONNECT_DELAY_MS
            lastError = null
            isConnecting = true
            notifyConnectionStateChanged()
            establishConnection()
        }
    }

    fun disconnect() {
        synchronized(lock) {
            intentionalDisconnect = true
            cancelReconnect()
            webSocket?.close(1000, "Client disconnecting")
            webSocket = null
            client?.dispatcher?.executorService?.shutdown()
            client = null
            isConnected = false
            isConnecting = false
            notifyConnectionStateChanged()
            Log.i(TAG, "Disconnected intentionally")
        }
    }

    fun send(message: Any) {
        synchronized(lock) {
            val ws = webSocket ?: return
            try {
                val json = gson.toJson(message)
                ws.send(json)
            } catch (e: Exception) {
                Log.e(TAG, "Send error: ${e.message}")
            }
        }
    }

    private fun establishConnection() {
        val url = serverUrl ?: return

        webSocket?.close(1000, null)
        client?.dispatcher?.executorService?.shutdown()

        val httpClient = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .writeTimeout(10, TimeUnit.SECONDS)
            .pingInterval(30, TimeUnit.SECONDS)
            .build()
        client = httpClient

        val request = Request.Builder()
            .url(url)
            .build()

        Log.i(TAG, "Connecting to $url")

        webSocket = httpClient.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                Log.i(TAG, "Connected successfully")
                synchronized(lock) {
                    isConnected = true
                    isConnecting = false
                    lastError = null
                    reconnectDelay = INITIAL_RECONNECT_DELAY_MS
                }
                notifyConnectionStateChanged()
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handleMessage(text)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.e(TAG, "Connection failure: ${t.message}")
                synchronized(lock) {
                    lastError = t.message ?: "Connection failed"
                }
                handleDisconnect()
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                Log.i(TAG, "Connection closed: $code $reason")
                handleDisconnect()
            }
        })
    }

    private fun handleMessage(text: String) {
        try {
            val envelope = gson.fromJson(text, MessageEnvelope::class.java)

            when (envelope.type) {
                "layout_update" -> {
                    val update = gson.fromJson(text, LayoutUpdate::class.java)
                    Log.i(TAG, "layout_update: ${update.windows.size} windows")
                    mainHandler.post { onLayoutUpdate?.invoke(update) }
                }
                "state_change" -> {
                    val json = gson.fromJson(text, Map::class.java)
                    val windowId = json["windowId"] as? String ?: return
                    val state = json["state"] as? String ?: return
                    mainHandler.post { onStateChange?.invoke(windowId, state) }
                }
                else -> {
                    Log.w(TAG, "Unknown message type: ${envelope.type}")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse message: ${e.message}")
        }
    }

    private fun handleDisconnect() {
        synchronized(lock) {
            if (intentionalDisconnect) return

            isConnected = false
            isConnecting = true
            webSocket = null
        }
        notifyConnectionStateChanged()

        Log.i(TAG, "Will reconnect in ${reconnectDelay}ms")

        val delay = reconnectDelay
        cancelReconnect()

        val runnable = Runnable {
            synchronized(lock) {
                if (intentionalDisconnect) return@Runnable
                reconnectDelay = (reconnectDelay * 2).coerceAtMost(MAX_RECONNECT_DELAY_MS)
                establishConnection()
            }
        }
        reconnectRunnable = runnable
        reconnectHandler.postDelayed(runnable, delay)
    }

    private fun cancelReconnect() {
        reconnectRunnable?.let { reconnectHandler.removeCallbacks(it) }
        reconnectRunnable = null
    }

    private fun notifyConnectionStateChanged() {
        mainHandler.post { onConnectionStateChanged?.invoke() }
    }
}
