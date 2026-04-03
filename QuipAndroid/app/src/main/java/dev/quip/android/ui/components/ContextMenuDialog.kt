package dev.quip.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Divider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import dev.quip.android.models.WindowState

@Composable
fun ContextMenuDialog(
    window: WindowState,
    onAction: (String, String) -> Unit,
    onDismiss: () -> Unit
) {
    val windowColor = parseHexColor(window.color)

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(16.dp),
            color = Color(0xFF2A2A2A),
            tonalElevation = 8.dp
        ) {
            Column(modifier = Modifier.padding(vertical = 8.dp)) {
                // Header
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .padding(horizontal = 20.dp, vertical = 12.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(10.dp)
                            .clip(CircleShape)
                            .background(windowColor)
                    )
                    Spacer(modifier = Modifier.width(10.dp))
                    Column {
                        Text(
                            text = window.name,
                            color = Color.White,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold
                        )
                        Text(
                            text = window.app,
                            color = Color.White.copy(alpha = 0.4f),
                            fontSize = 11.sp
                        )
                    }
                }

                Divider(color = Color.White.copy(alpha = 0.08f))

                // Action rows
                ContextActionRow(
                    label = "Press Return",
                    color = windowColor,
                    onClick = {
                        onAction(window.id, "press_return")
                        onDismiss()
                    }
                )
                ContextActionRow(
                    label = "Cancel (Ctrl+C)",
                    color = windowColor,
                    onClick = {
                        onAction(window.id, "press_ctrl_c")
                        onDismiss()
                    }
                )
                ContextActionRow(
                    label = "View Output",
                    color = windowColor,
                    onClick = {
                        onAction(window.id, "view_output")
                        onDismiss()
                    }
                )
                ContextActionRow(
                    label = "Clear Context",
                    color = windowColor,
                    onClick = {
                        onAction(window.id, "clear_terminal")
                        onDismiss()
                    }
                )
                ContextActionRow(
                    label = "Restart Claude",
                    color = windowColor,
                    onClick = {
                        onAction(window.id, "restart_claude")
                        onDismiss()
                    }
                )

                Divider(
                    color = Color.White.copy(alpha = 0.08f),
                    modifier = Modifier.padding(vertical = 4.dp)
                )

                ContextActionRow(
                    label = if (window.enabled) "Disable Window" else "Enable Window",
                    color = if (window.enabled) Color(0xFFE05050) else windowColor,
                    onClick = {
                        onAction(window.id, "toggle_enabled")
                        onDismiss()
                    }
                )
            }
        }
    }
}

@Composable
private fun ContextActionRow(
    label: String,
    color: Color,
    onClick: () -> Unit
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 14.dp)
    ) {
        Text(
            text = label,
            color = color.copy(alpha = 0.85f),
            fontSize = 14.sp
        )
    }
}
