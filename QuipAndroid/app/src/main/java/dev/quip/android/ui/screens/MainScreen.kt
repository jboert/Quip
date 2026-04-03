package dev.quip.android.ui.screens

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import dev.quip.android.models.SavedConnection
import dev.quip.android.models.WindowState
import dev.quip.android.services.DiscoveredHost

@Composable
fun MainScreen(
    isConnected: Boolean,
    isConnecting: Boolean,
    isRecording: Boolean,
    windows: List<WindowState>,
    selectedWindowId: String?,
    monitorName: String,
    urlText: String,
    onUrlChange: (String) -> Unit,
    onConnect: (String) -> Unit,
    onDisconnect: () -> Unit,
    onPaste: () -> Unit,
    discoveredHosts: List<DiscoveredHost>,
    recentConnections: List<SavedConnection>,
    onPinToggle: (SavedConnection) -> Unit,
    onRename: (SavedConnection, String) -> Unit,
    onDelete: (SavedConnection) -> Unit,
    onScanQR: () -> Unit,
    onSelectWindow: (String) -> Unit,
    onWindowAction: (String, String) -> Unit,
    onStopRecording: () -> Unit,
    modifier: Modifier = Modifier
) {
    if (isConnected || isConnecting) {
        LayoutScreen(
            windows = windows,
            selectedWindowId = selectedWindowId,
            isConnected = isConnected,
            isRecording = isRecording,
            monitorName = monitorName,
            onSelectWindow = onSelectWindow,
            onWindowAction = onWindowAction,
            onStopRecording = onStopRecording,
            onDisconnect = onDisconnect,
            modifier = modifier
        )
    } else {
        ConnectionScreen(
            urlText = urlText,
            onUrlChange = onUrlChange,
            onConnect = onConnect,
            onPaste = onPaste,
            discoveredHosts = discoveredHosts,
            recentConnections = recentConnections,
            onPinToggle = onPinToggle,
            onRename = onRename,
            onDelete = onDelete,
            onScanQR = onScanQR,
            modifier = modifier
        )
    }
}
