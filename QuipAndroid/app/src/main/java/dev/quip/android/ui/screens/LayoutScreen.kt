package dev.quip.android.ui.screens

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.quip.android.models.WindowState
import dev.quip.android.ui.components.ContextMenuDialog
import dev.quip.android.ui.components.WindowTile
import dev.quip.android.ui.components.parseHexColor

@Composable
fun LayoutScreen(
    windows: List<WindowState>,
    selectedWindowId: String?,
    isConnected: Boolean,
    isRecording: Boolean,
    monitorName: String,
    onSelectWindow: (String) -> Unit,
    onWindowAction: (String, String) -> Unit,
    onStopRecording: () -> Unit,
    onDisconnect: () -> Unit,
    showTextInput: Boolean = false,
    textInputValue: String = "",
    onTextInputChange: (String) -> Unit = {},
    onToggleTextInput: () -> Unit = {},
    onSendTextInput: () -> Unit = {},
    modifier: Modifier = Modifier
) {
    var contextMenuWindow by remember { mutableStateOf<WindowState?>(null) }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(
                Brush.linearGradient(
                    colors = listOf(
                        Color(0xFF101014),
                        Color(0xFF1A1A1E),
                        Color(0xFF121216)
                    )
                )
            )
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            // Top status bar
            TopStatusBar(
                isConnected = isConnected,
                isRecording = isRecording,
                monitorName = monitorName,
                onDisconnect = onDisconnect
            )

            // Window layout area
            BoxWithConstraints(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp, vertical = 8.dp)
            ) {
                val screenWidthDp = maxWidth
                val screenHeightDp = maxHeight
                val inset = 8.dp

                if (windows.isEmpty()) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center,
                        modifier = Modifier.fillMaxSize()
                    ) {
                        Text(
                            text = if (isConnected) "No windows detected" else "Connect to see windows",
                            color = Color.White.copy(alpha = 0.25f),
                            fontSize = 14.sp
                        )
                    }
                } else {
                    val enabledWindows = windows.filter { it.enabled || it.id == selectedWindowId }
                    enabledWindows.forEach { window ->
                        val xDp = inset + (screenWidthDp - inset * 2) * window.frame.x.toFloat()
                        val yDp = inset + (screenHeightDp - inset * 2) * window.frame.y.toFloat()
                        val wDp = (screenWidthDp - inset * 2) * window.frame.width.toFloat()
                        val hDp = (screenHeightDp - inset * 2) * window.frame.height.toFloat()

                        WindowTile(
                            window = window,
                            isSelected = window.id == selectedWindowId,
                            isRecording = isRecording && window.id == selectedWindowId,
                            onClick = { onSelectWindow(window.id) },
                            onLongClick = { contextMenuWindow = window },
                            modifier = Modifier
                                .offset(x = xDp, y = yDp)
                                .size(width = wDp, height = hDp)
                        )
                    }
                }
            }

            // Text input bar
            if (showTextInput) {
                TextInputBar(
                    value = textInputValue,
                    onValueChange = onTextInputChange,
                    onSend = onSendTextInput
                )
            }

            // Bottom bar: selected window indicator
            BottomBar(
                windows = windows,
                selectedWindowId = selectedWindowId,
                showKeyboard = isConnected,
                isTextInputVisible = showTextInput,
                onToggleTextInput = onToggleTextInput
            )
        }

        // Recording overlay
        if (isRecording) {
            RecordingOverlay(onStopRecording = onStopRecording)
        }

        // Context menu dialog
        contextMenuWindow?.let { window ->
            ContextMenuDialog(
                window = window,
                onAction = { windowId, action ->
                    onWindowAction(windowId, action)
                },
                onDismiss = { contextMenuWindow = null }
            )
        }
    }
}

@Composable
private fun TopStatusBar(
    isConnected: Boolean,
    isRecording: Boolean,
    monitorName: String,
    onDisconnect: () -> Unit
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .background(Color.Black.copy(alpha = 0.3f))
            .padding(horizontal = 12.dp, vertical = 6.dp)
    ) {
        // Connection dot
        Box(
            modifier = Modifier
                .size(6.dp)
                .clip(CircleShape)
                .background(if (isConnected) Color.Green else Color.Yellow)
        )
        Spacer(modifier = Modifier.width(6.dp))
        Text(
            text = if (isConnected) "Connected" else "Connecting...",
            color = Color.White.copy(alpha = 0.5f),
            fontSize = 10.sp,
            fontWeight = FontWeight.Medium
        )

        if (isRecording) {
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = "REC",
                color = Color(0xFFE6A619),
                fontSize = 9.sp,
                fontWeight = FontWeight.Bold
            )
        }

        Spacer(modifier = Modifier.weight(1f))

        Text(
            text = monitorName,
            color = Color.White.copy(alpha = 0.3f),
            fontSize = 10.sp
        )
        Spacer(modifier = Modifier.width(8.dp))
        Text(
            text = "\u2715", // x mark
            color = Color.White.copy(alpha = 0.4f),
            fontSize = 12.sp,
            modifier = Modifier.clickable(onClick = onDisconnect)
        )
    }
}

@Composable
private fun BottomBar(
    windows: List<WindowState>,
    selectedWindowId: String?,
    showKeyboard: Boolean = false,
    isTextInputVisible: Boolean = false,
    onToggleTextInput: () -> Unit = {}
) {
    val selected = windows.firstOrNull { it.id == selectedWindowId }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp)
    ) {
        if (selected != null) {
            Box(
                modifier = Modifier
                    .size(5.dp)
                    .clip(CircleShape)
                    .background(parseHexColor(selected.color))
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = selected.name,
                color = Color.White.copy(alpha = 0.4f),
                fontSize = 9.sp
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = selected.app,
                color = Color.White.copy(alpha = 0.2f),
                fontSize = 9.sp
            )
        }
        Spacer(modifier = Modifier.weight(1f))
        if (showKeyboard) {
            Text(
                text = if (isTextInputVisible) "\u2328\u2193" else "\u2328",
                color = Color.White.copy(alpha = 0.5f),
                fontSize = 14.sp,
                modifier = Modifier.clickable(onClick = onToggleTextInput)
            )
        }
    }
}

@Composable
private fun TextInputBar(
    value: String,
    onValueChange: (String) -> Unit,
    onSend: () -> Unit
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .background(Color(0xFF101014))
            .padding(horizontal = 8.dp, vertical = 4.dp)
    ) {
        TextField(
            value = value,
            onValueChange = onValueChange,
            placeholder = {
                Text(
                    "Type a prompt\u2026",
                    color = Color.White.copy(alpha = 0.3f),
                    fontSize = 12.sp,
                    fontFamily = FontFamily.Monospace
                )
            },
            textStyle = TextStyle(
                color = Color.White,
                fontSize = 12.sp,
                fontFamily = FontFamily.Monospace
            ),
            colors = TextFieldDefaults.colors(
                focusedContainerColor = Color.White.copy(alpha = 0.08f),
                unfocusedContainerColor = Color.White.copy(alpha = 0.08f),
                cursorColor = Color.White,
                focusedIndicatorColor = Color.Transparent,
                unfocusedIndicatorColor = Color.Transparent
            ),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { onSend() }),
            singleLine = true,
            modifier = Modifier
                .weight(1f)
                .height(40.dp)
                .clip(RoundedCornerShape(6.dp))
        )
        Spacer(modifier = Modifier.width(6.dp))
        IconButton(
            onClick = onSend,
            enabled = value.isNotBlank(),
            modifier = Modifier.size(32.dp)
        ) {
            Text(
                text = "\u2191",
                color = if (value.isNotBlank()) Color(0xFF3B82F6) else Color.White.copy(alpha = 0.2f),
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold
            )
        }
    }
}

@Composable
private fun RecordingOverlay(onStopRecording: () -> Unit) {
    val infiniteTransition = rememberInfiniteTransition(label = "recPulse")
    val alpha by infiniteTransition.animateFloat(
        initialValue = 0.5f,
        targetValue = 1.0f,
        animationSpec = infiniteRepeatable(
            animation = tween(600),
            repeatMode = RepeatMode.Reverse
        ),
        label = "recAlpha"
    )

    Box(
        modifier = Modifier
            .fillMaxSize()
            .clickable(onClick = onStopRecording),
        contentAlignment = Alignment.BottomCenter
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .padding(bottom = 24.dp)
                .clip(RoundedCornerShape(50))
                .background(Color.Red.copy(alpha = 0.2f))
                .padding(horizontal = 16.dp, vertical = 8.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(10.dp)
                    .clip(CircleShape)
                    .background(Color.Red.copy(alpha = alpha))
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = "Recording \u2014 tap to stop",
                color = Color.White.copy(alpha = 0.8f),
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium
            )
        }
    }
}
