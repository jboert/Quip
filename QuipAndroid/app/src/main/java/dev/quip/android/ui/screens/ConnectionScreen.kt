package dev.quip.android.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.quip.android.models.SavedConnection
import dev.quip.android.services.DiscoveredHost
import dev.quip.android.ui.theme.AmberPrimary
import dev.quip.android.ui.theme.LocalQuipColors

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectionScreen(
    urlText: String,
    onUrlChange: (String) -> Unit,
    onConnect: (String) -> Unit,
    onPaste: () -> Unit,
    discoveredHosts: List<DiscoveredHost>,
    recentConnections: List<SavedConnection>,
    onPinToggle: (SavedConnection) -> Unit,
    onRename: (SavedConnection, String) -> Unit,
    onDelete: (SavedConnection) -> Unit,
    onScanQR: () -> Unit,
    modifier: Modifier = Modifier
) {
    val colors = LocalQuipColors.current
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier
            .fillMaxSize()
            .background(colors.background)
            .padding(horizontal = 20.dp, vertical = 32.dp)
    ) {
        // Title
        Text(
            text = "Quip",
            color = AmberPrimary,
            fontSize = 28.sp,
            fontWeight = FontWeight.Bold
        )

        Spacer(modifier = Modifier.height(24.dp))

        // URL bar row — text field + paste + QR + connect
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()
        ) {
            // URL text field
            TextField(
                value = urlText,
                onValueChange = onUrlChange,
                placeholder = {
                    Text(
                        "ws://192.168.x.x:8765",
                        color = colors.textFaint,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 13.sp
                    )
                },
                singleLine = true,
                textStyle = LocalTextStyle.current.copy(
                    fontFamily = FontFamily.Monospace,
                    fontSize = 13.sp,
                    color = colors.textPrimary
                ),
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Uri,
                    imeAction = ImeAction.Go
                ),
                keyboardActions = KeyboardActions(onGo = { onConnect(urlText) }),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = colors.surface,
                    unfocusedContainerColor = colors.surface,
                    focusedTextColor = colors.textPrimary,
                    unfocusedTextColor = colors.textPrimary,
                    cursorColor = AmberPrimary,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent
                ),
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier
                    .weight(1f)
                    .height(48.dp)
            )

            Spacer(modifier = Modifier.width(6.dp))

            // Paste button
            IconButton(
                onClick = onPaste,
                modifier = Modifier
                    .size(40.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(colors.surface)
            ) {
                Text(
                    text = "\uD83D\uDCCB", // clipboard emoji
                    fontSize = 16.sp
                )
            }

            Spacer(modifier = Modifier.width(4.dp))

            // QR button
            IconButton(
                onClick = onScanQR,
                modifier = Modifier
                    .size(40.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(colors.surface)
            ) {
                Text(
                    text = "\u25A3", // QR-like square
                    fontSize = 18.sp,
                    color = colors.textSecondary
                )
            }

            Spacer(modifier = Modifier.width(6.dp))

            // Connect button
            Button(
                onClick = { onConnect(urlText) },
                enabled = urlText.isNotBlank(),
                colors = ButtonDefaults.buttonColors(
                    containerColor = AmberPrimary,
                    contentColor = colors.background
                ),
                shape = RoundedCornerShape(8.dp),
                contentPadding = PaddingValues(horizontal = 16.dp),
                modifier = Modifier.height(40.dp)
            ) {
                Text("Connect", fontWeight = FontWeight.Bold, fontSize = 13.sp)
            }
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
    }
}

@Composable
private fun SectionHeader(text: String) {
    val colors = LocalQuipColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
    ) {
        Divider(
            color = colors.divider,
            modifier = Modifier.weight(1f)
        )
        Text(
            text = text,
            color = colors.textTertiary,
            fontSize = 11.sp,
            modifier = Modifier.padding(horizontal = 12.dp)
        )
        Divider(
            color = colors.divider,
            modifier = Modifier.weight(1f)
        )
    }
}

@Composable
private fun DiscoveredHostRow(
    host: DiscoveredHost,
    onClick: () -> Unit
) {
    val colors = LocalQuipColors.current
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
                color = colors.textPrimary.copy(alpha = 0.8f),
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium
            )
            Text(
                text = "${host.host}:${host.port}",
                color = colors.textTertiary,
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
    val colors = LocalQuipColors.current
    var showMenu by remember { mutableStateOf(false) }

    Box {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .background(colors.surface)
                .clickable(onClick = onClick)
                .padding(horizontal = 12.dp, vertical = 10.dp)
        ) {
            if (connection.pinned) {
                Text(
                    text = "\uD83D\uDCCC",
                    fontSize = 10.sp,
                    modifier = Modifier.padding(end = 6.dp)
                )
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = connection.displayName,
                    color = colors.textPrimary.copy(alpha = 0.8f),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    text = connection.url,
                    color = colors.textTertiary,
                    fontSize = 10.sp,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Text(
                text = "\u22EE",
                color = colors.textTertiary,
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
                onClick = { showMenu = false; onPinToggle() }
            )
            DropdownMenuItem(
                text = { Text("Rename") },
                onClick = { showMenu = false; onRename(connection.displayName) }
            )
            DropdownMenuItem(
                text = { Text("Delete", color = colors.destructive) },
                onClick = { showMenu = false; onDelete() }
            )
        }
    }
}
