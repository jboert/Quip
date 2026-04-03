package dev.quip.android.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Divider
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.quip.android.models.SavedConnection
import dev.quip.android.services.DiscoveredHost
import dev.quip.android.ui.theme.AmberPrimary
import dev.quip.android.ui.theme.DarkBackground
import dev.quip.android.ui.theme.DarkSurface

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectionScreen(
    urlText: String,
    onUrlChange: (String) -> Unit,
    onConnect: (String) -> Unit,
    discoveredHosts: List<DiscoveredHost>,
    recentConnections: List<SavedConnection>,
    onPinToggle: (SavedConnection) -> Unit,
    onRename: (SavedConnection, String) -> Unit,
    onDelete: (SavedConnection) -> Unit,
    onScanQR: () -> Unit,
    modifier: Modifier = Modifier
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier
            .fillMaxSize()
            .background(DarkBackground)
            .padding(horizontal = 24.dp, vertical = 32.dp)
    ) {
        // Title
        Text(
            text = "Quip",
            color = AmberPrimary,
            fontSize = 32.sp,
            fontWeight = FontWeight.Bold
        )

        Spacer(modifier = Modifier.height(32.dp))

        // URL input
        TextField(
            value = urlText,
            onValueChange = onUrlChange,
            placeholder = {
                Text(
                    "ws://192.168.x.x:8765",
                    color = Color.White.copy(alpha = 0.3f),
                    fontFamily = FontFamily.Monospace
                )
            },
            singleLine = true,
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Uri,
                imeAction = ImeAction.Go
            ),
            keyboardActions = KeyboardActions(onGo = { onConnect(urlText) }),
            colors = TextFieldDefaults.textFieldColors(
                containerColor = DarkSurface,
                focusedTextColor = Color.White,
                unfocusedTextColor = Color.White,
                cursorColor = AmberPrimary,
                focusedIndicatorColor = AmberPrimary,
                unfocusedIndicatorColor = Color.White.copy(alpha = 0.15f)
            ),
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(modifier = Modifier.height(12.dp))

        // Connect button
        Button(
            onClick = { onConnect(urlText) },
            enabled = urlText.isNotBlank(),
            colors = ButtonDefaults.buttonColors(
                containerColor = AmberPrimary,
                contentColor = DarkBackground
            ),
            shape = RoundedCornerShape(8.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Connect", fontWeight = FontWeight.Bold)
        }

        Spacer(modifier = Modifier.height(24.dp))

        // Discovered on network
        if (discoveredHosts.isNotEmpty()) {
            SectionHeader("Discovered on network")
            Spacer(modifier = Modifier.height(8.dp))
            discoveredHosts.forEach { host ->
                DiscoveredHostRow(
                    host = host,
                    onClick = { onConnect(host.wsUrl) }
                )
                Spacer(modifier = Modifier.height(4.dp))
            }
            Spacer(modifier = Modifier.height(16.dp))
        }

        // Recent connections
        if (recentConnections.isNotEmpty()) {
            SectionHeader("Recent connections")
            Spacer(modifier = Modifier.height(8.dp))
            LazyColumn(modifier = Modifier.weight(1f)) {
                val sorted = recentConnections.sortedWith(
                    compareByDescending<SavedConnection> { it.pinned }
                        .thenByDescending { it.lastUsed }
                )
                items(sorted, key = { it.id }) { conn ->
                    RecentConnectionRow(
                        connection = conn,
                        onClick = { onConnect(conn.url) },
                        onPinToggle = { onPinToggle(conn) },
                        onRename = { newName -> onRename(conn, newName) },
                        onDelete = { onDelete(conn) }
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                }
            }
        } else {
            Spacer(modifier = Modifier.weight(1f))
        }

        Spacer(modifier = Modifier.height(16.dp))

        // Scan QR button
        OutlinedButton(
            onClick = onScanQR,
            shape = RoundedCornerShape(8.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Scan QR Code", color = Color.White.copy(alpha = 0.7f))
        }
    }
}

@Composable
private fun SectionHeader(text: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
    ) {
        Divider(
            color = Color.White.copy(alpha = 0.1f),
            modifier = Modifier.weight(1f)
        )
        Text(
            text = text,
            color = Color.White.copy(alpha = 0.4f),
            fontSize = 11.sp,
            modifier = Modifier.padding(horizontal = 12.dp)
        )
        Divider(
            color = Color.White.copy(alpha = 0.1f),
            modifier = Modifier.weight(1f)
        )
    }
}

@Composable
private fun DiscoveredHostRow(
    host: DiscoveredHost,
    onClick: () -> Unit
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(Color.Green.copy(alpha = 0.06f))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp)
    ) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(Color.Green.copy(alpha = 0.7f))
        )
        Spacer(modifier = Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = host.name,
                color = Color.White.copy(alpha = 0.8f),
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium
            )
            Text(
                text = "${host.host}:${host.port}",
                color = Color.White.copy(alpha = 0.3f),
                fontSize = 10.sp,
                fontFamily = FontFamily.Monospace
            )
        }
        Text(
            text = "Local",
            color = Color.Green.copy(alpha = 0.5f),
            fontSize = 9.sp,
            fontWeight = FontWeight.Medium
        )
    }
}

@Composable
private fun RecentConnectionRow(
    connection: SavedConnection,
    onClick: () -> Unit,
    onPinToggle: () -> Unit,
    onRename: (String) -> Unit,
    onDelete: () -> Unit
) {
    var showMenu by remember { mutableStateOf(false) }

    Box {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .background(Color.White.copy(alpha = 0.06f))
                .clickable(onClick = onClick)
                .padding(horizontal = 12.dp, vertical = 10.dp)
        ) {
            if (connection.pinned) {
                Text(
                    text = "\uD83D\uDCCC", // pin emoji
                    fontSize = 10.sp,
                    modifier = Modifier.padding(end = 6.dp)
                )
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = connection.displayName,
                    color = Color.White.copy(alpha = 0.8f),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1
                )
                Text(
                    text = connection.url,
                    color = Color.White.copy(alpha = 0.3f),
                    fontSize = 10.sp,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1
                )
            }
            // Long press triggers dropdown
            Text(
                text = "\u22EE", // vertical ellipsis
                color = Color.White.copy(alpha = 0.3f),
                fontSize = 18.sp,
                modifier = Modifier
                    .clickable { showMenu = true }
                    .padding(start = 8.dp, end = 4.dp)
            )
        }

        DropdownMenu(
            expanded = showMenu,
            onDismissRequest = { showMenu = false }
        ) {
            DropdownMenuItem(
                text = { Text(if (connection.pinned) "Unpin" else "Pin to Top") },
                onClick = {
                    showMenu = false
                    onPinToggle()
                }
            )
            DropdownMenuItem(
                text = { Text("Rename") },
                onClick = {
                    showMenu = false
                    // For simplicity, rename to display name + " (renamed)"
                    // In a real app, this would show an input dialog
                    onRename(connection.displayName)
                }
            )
            DropdownMenuItem(
                text = { Text("Delete", color = Color(0xFFE05050)) },
                onClick = {
                    showMenu = false
                    onDelete()
                }
            )
        }
    }
}
