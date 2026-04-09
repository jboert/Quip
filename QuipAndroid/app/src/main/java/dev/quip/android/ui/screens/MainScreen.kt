package dev.quip.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.quip.android.models.SavedConnection
import dev.quip.android.models.WindowState
import dev.quip.android.services.DiscoveredHost

@Composable
fun MainScreen(
    isConnected: Boolean,
    isConnecting: Boolean,
    isAuthenticated: Boolean,
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
    transcribedText: String = "",
    onSelectWindow: (String) -> Unit,
    onWindowAction: (String, String) -> Unit,
    onStopRecording: () -> Unit,
    showPinEntry: Boolean = false,
    pinText: String = "",
    onPinChange: (String) -> Unit = {},
    onSendAuth: () -> Unit = {},
    authError: String? = null,
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
    showUrlWarning: Boolean = false,
    pendingUnsafeUrl: String? = null,
    onConnectAnyway: () -> Unit = {},
    onDismissUrlWarning: () -> Unit = {},
    modifier: Modifier = Modifier
) {
    if (showUrlWarning && pendingUnsafeUrl != null) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = onDismissUrlWarning,
            title = { Text("Unrecognized Server") },
            text = {
                Text(
                    "This URL doesn't match expected patterns (local network or Cloudflare tunnel):" +
                    "\n\n$pendingUnsafeUrl\n\n" +
                    "Connecting to an unknown server could expose your data."
                )
            },
            confirmButton = {
                TextButton(onClick = onConnectAnyway) {
                    Text("Connect Anyway", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = onDismissUrlWarning) {
                    Text("Cancel")
                }
            }
        )
    }
    Box(modifier = modifier) {
    if (isConnected && showPinEntry && !isAuthenticated) {
        PinEntryContent(
            pinText = pinText,
            onPinChange = onPinChange,
            onSubmit = onSendAuth,
            authError = authError,
            onDisconnect = onDisconnect
        )
    } else if (isConnected && isAuthenticated || isConnecting) {
        LayoutScreen(
            windows = windows,
            selectedWindowId = selectedWindowId,
            isConnected = isConnected,
            isRecording = isRecording,
            transcribedText = transcribedText,
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

@Composable
private fun PinEntryContent(
    pinText: String,
    onPinChange: (String) -> Unit,
    onSubmit: () -> Unit,
    authError: String?,
    onDisconnect: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "Enter PIN",
            style = MaterialTheme.typography.headlineMedium
        )

        Spacer(modifier = Modifier.height(8.dp))

        Text(
            text = "Enter the PIN shown on your desktop app",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(24.dp))

        OutlinedTextField(
            value = pinText,
            onValueChange = { value ->
                // Only allow digits, max 12 characters
                val filtered = value.filter { it.isDigit() }.take(12)
                onPinChange(filtered)
            },
            label = { Text("PIN") },
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.NumberPassword,
                imeAction = ImeAction.Done
            ),
            keyboardActions = KeyboardActions(
                onDone = { if (pinText.length >= 4) onSubmit() }
            ),
            singleLine = true,
            modifier = Modifier.width(200.dp),
            isError = authError != null
        )

        if (authError != null) {
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = authError,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
                textAlign = TextAlign.Center
            )
        }

        Spacer(modifier = Modifier.height(16.dp))

        Button(
            onClick = onSubmit,
            enabled = pinText.length >= 4,
            modifier = Modifier.fillMaxWidth(0.5f)
        ) {
            Text("Authenticate")
        }

        Spacer(modifier = Modifier.height(8.dp))

        TextButton(onClick = onDisconnect) {
            Text("Disconnect")
        }
    }
}
