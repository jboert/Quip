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
    showTextInput: Boolean = false,
    textInputValue: String = "",
    onTextInputChange: (String) -> Unit = {},
    onToggleTextInput: () -> Unit = {},
    onSendTextInput: () -> Unit = {},
    terminalContentText: String? = null,
    terminalContentScreenshot: String? = null,
    terminalContentWindowName: String = "Terminal",
    onDismissContent: () -> Unit = {},
    onRefreshContent: () -> Unit = {},
    onSendTerminalAction: (String) -> Unit = {},
    modifier: Modifier = Modifier
) {
    androidx.compose.foundation.layout.Box(modifier = modifier) {
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
            showTextInput = showTextInput,
            textInputValue = textInputValue,
            onTextInputChange = onTextInputChange,
            onToggleTextInput = onToggleTextInput,
            onSendTextInput = onSendTextInput
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
            onScanQR = onScanQR
        )
    }

    if (terminalContentText != null) {
        dev.quip.android.ui.components.TerminalContentOverlay(
            content = terminalContentText,
            screenshot = terminalContentScreenshot,
            windowName = terminalContentWindowName,
            onDismiss = onDismissContent,
            onRefresh = onRefreshContent,
            onSendAction = onSendTerminalAction
        )
    }
    }
}
