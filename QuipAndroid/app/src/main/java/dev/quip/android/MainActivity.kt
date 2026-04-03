package dev.quip.android

import android.Manifest
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.KeyEvent
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModelProvider
import dev.quip.android.ui.screens.MainScreen
import dev.quip.android.ui.theme.QuipTheme

class MainActivity : ComponentActivity() {

    private lateinit var vm: MainViewModel

    private var showQrScanner by mutableStateOf(false)

    private val cameraPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) showQrScanner = true
        else Toast.makeText(this, "Camera permission required for QR scanning", Toast.LENGTH_SHORT).show()
    }

    private val audioPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (!granted) {
            Toast.makeText(this, "Microphone permission required for voice input", Toast.LENGTH_SHORT).show()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            audioPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }

        vm = ViewModelProvider(this)[MainViewModel::class.java]
        vm.onRequestOrientation = { requestedOrientation = it }

        if (savedInstanceState == null) {
            vm.initialize()
        }

        setContent {
            QuipTheme {
                if (showQrScanner) {
                    dev.quip.android.ui.screens.QrScannerScreen(
                        onScanned = { value ->
                            showQrScanner = false
                            vm.urlText = value
                            vm.connect(value)
                        },
                        onDismiss = { showQrScanner = false }
                    )
                } else {
                    MainScreen(
                        isConnected = vm.isConnected,
                        isConnecting = vm.isConnecting,
                        isRecording = vm.isRecording,
                        windows = vm.windows.toList(),
                        selectedWindowId = vm.selectedWindowId,
                        monitorName = vm.monitorName,
                        urlText = vm.urlText,
                        onUrlChange = { vm.urlText = it },
                        onConnect = { url -> vm.connect(url) },
                        onDisconnect = { vm.disconnect() },
                        onPaste = { vm.pasteFromClipboard() },
                        discoveredHosts = vm.discoveredHosts.toList(),
                        recentConnections = vm.recentConnections.toList(),
                        onPinToggle = { conn -> vm.togglePin(conn) },
                        onRename = { conn, name -> vm.renameConnection(conn, name) },
                        onDelete = { conn -> vm.deleteConnection(conn) },
                        onScanQR = { requestQrScan() },
                        onSelectWindow = { windowId -> vm.selectWindow(windowId) },
                        onWindowAction = { windowId, action -> vm.handleWindowAction(windowId, action) },
                        onStopRecording = { vm.stopRecording() },
                        terminalContentText = vm.terminalContentText,
                        terminalContentWindowName = vm.terminalContentWindowName,
                        onDismissContent = { vm.dismissTerminalContent() },
                        onRefreshContent = { vm.refreshTerminalContent() }
                    )
                }
            }
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_DOWN -> {
                if (!vm.isRecording) vm.startRecording(this) else vm.stopRecording()
                return true
            }
            KeyEvent.KEYCODE_VOLUME_UP -> {
                if (!vm.isRecording) vm.cycleSelectedWindow() else vm.stopRecording()
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            return true
        }
        return super.onKeyUp(keyCode, event)
    }

    private fun requestQrScan() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            == PackageManager.PERMISSION_GRANTED
        ) {
            showQrScanner = true
        } else {
            cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
        }
    }
}
