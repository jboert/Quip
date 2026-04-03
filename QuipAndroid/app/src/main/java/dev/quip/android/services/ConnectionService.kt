package dev.quip.android.services

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import androidx.core.app.NotificationCompat
import dev.quip.android.MainActivity
import dev.quip.android.R

/**
 * Foreground service that shows a persistent notification with the current
 * WebSocket connection status. Started when a connection is established,
 * stopped when intentionally disconnected.
 */
class ConnectionService : Service() {

    companion object {
        private const val CHANNEL_ID = "quip_connection"
        private const val NOTIFICATION_ID = 1

        const val ACTION_UPDATE_STATUS = "dev.quip.android.UPDATE_STATUS"
        const val EXTRA_CONNECTED = "connected"
        const val EXTRA_SERVER_NAME = "server_name"

        fun start(context: Context, serverName: String) {
            val intent = Intent(context, ConnectionService::class.java).apply {
                action = ACTION_UPDATE_STATUS
                putExtra(EXTRA_CONNECTED, true)
                putExtra(EXTRA_SERVER_NAME, serverName)
            }
            context.startForegroundService(intent)
        }

        fun updateDisconnected(context: Context) {
            val intent = Intent(context, ConnectionService::class.java).apply {
                action = ACTION_UPDATE_STATUS
                putExtra(EXTRA_CONNECTED, false)
            }
            context.startService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ConnectionService::class.java))
        }
    }

    private var isConnected = false
    private var serverName = ""

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification(false, ""))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_UPDATE_STATUS -> {
                isConnected = intent.getBooleanExtra(EXTRA_CONNECTED, false)
                serverName = intent.getStringExtra(EXTRA_SERVER_NAME) ?: serverName

                val manager = getSystemService(NotificationManager::class.java)
                manager.notify(NOTIFICATION_ID, buildNotification(isConnected, serverName))

                if (!isConnected) {
                    stopSelf()
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Connection Status",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shows Quip connection status"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(connected: Boolean, server: String): Notification {
        val tapIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, tapIntent, PendingIntent.FLAG_IMMUTABLE
        )

        val title = if (connected) "Connected" else "Disconnected"
        val text = if (connected && server.isNotEmpty()) "Connected to $server" else "Not connected"
        val icon = if (connected) R.drawable.ic_connected else R.drawable.ic_disconnected

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(icon)
            .setOngoing(connected)
            .setContentIntent(pendingIntent)
            .setSilent(true)
            .build()
    }
}
