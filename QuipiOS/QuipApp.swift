import SwiftUI
import AVFoundation

// Controls orientation lock — portrait when disconnected, all orientations when connected
class AppOrientationDelegate: NSObject, UIApplicationDelegate {
    static var allowAllOrientations = false

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.allowAllOrientations ? .allButUpsideDown : .portrait
    }
}

@main
struct QuipApp: App {
    @UIApplicationDelegateAdaptor(AppOrientationDelegate.self) var appDelegate
    @State private var client = WebSocketClient()
    @State private var speech = SpeechService()
    @State private var volumeHandler = HardwareButtonHandler()
    @State private var bonjourBrowser = BonjourBrowser()

    @State private var windows: [WindowState] = []
    @State private var selectedWindowId: String?
    @State private var monitorName: String = "Mac"
    @State private var screenAspect: Double = 16.0 / 10.0
    @State private var isRecording = false
    @State private var pttTracker = PTTWindowTracker()
    @State private var terminalContentText: String?
    @State private var terminalContentScreenshot: String?
    @State private var terminalContentWindowId: String?
    @State private var showPINEntry = false
    @State private var pinText = ""
    @State private var projectDirectories: [String] = []
    @State private var errorToast: String?
    @AppStorage("ttsEnabled") private var ttsEnabled = false
    /// Output delta text per window — used to display TTS overlay captions
    @State private var ttsOverlayTexts: [String: String] = [:]

    var body: some Scene {
        WindowGroup {
            MainiOSView(
                client: client,
                speech: speech,
                bonjourBrowser: bonjourBrowser,
                windows: $windows,
                selectedWindowId: $selectedWindowId,
                isRecording: $isRecording,
                terminalContentText: $terminalContentText,
                terminalContentScreenshot: $terminalContentScreenshot,
                terminalContentWindowId: $terminalContentWindowId,
                showPINEntry: $showPINEntry,
                pinText: $pinText,
                projectDirectories: projectDirectories,
                errorToast: $errorToast,
                ttsOverlayTexts: ttsOverlayTexts,
                monitorName: monitorName,
                screenAspect: screenAspect,
                onStartRecording: { DispatchQueue.main.async { startRecording() } },
                onStopRecording: { DispatchQueue.main.async { stopRecording() } },
                onRequestContent: { windowId in
                    client.send(RequestContentMessage(windowId: windowId))
                }
            )
            .onAppear {
                setup()
                bonjourBrowser.startBrowsing()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                // Only reset the audio session if TTS isn't actively playing —
                // background audio mode keeps the session alive during playback
                if !speech.isSpeaking {
                    volumeHandler.resumeAfterBackground()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                // Buy ~30s of background execution so a quick app switch doesn't
                // suspend the network stack and stale the WebSocket.
                client.suspendForBackground()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                // Probe the socket on return; force-reconnect with reset backoff
                // if the probe doesn't pong within 2s.
                client.resumeFromBackground()
            }
        }
    }

    private func setup() {
        speech.requestAuthorization()

        client.onLayoutUpdate = { update in
            DispatchQueue.main.async {
                let wasEmpty = windows.isEmpty
                windows = update.windows
                monitorName = update.monitor
                if let a = update.screenAspect, a > 0 { screenAspect = a }
                volumeHandler.startMonitoring(windowCount: update.windows.count)
                // Allow all orientations once we have windows, suggest landscape
                if wasEmpty && !update.windows.isEmpty {
                    AppOrientationDelegate.allowAllOrientations = true
                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .allButUpsideDown))
                    }
                    UIViewController.attemptRotationToDeviceOrientation()
                }
                // If the selected window vanished (Mac restarted, window closed),
                // auto-select the first available window so buttons don't go dead.
                if let wid = selectedWindowId, !update.windows.contains(where: { $0.id == wid }) {
                    selectedWindowId = update.windows.first?.id
                    if let newId = selectedWindowId {
                        client.send(SelectWindowMessage(windowId: newId))
                    }
                }
                // Tell the Mac which window we currently have selected — but only
                // if this is the first layout update after connection (wasEmpty = true).
                if wasEmpty, let wid = selectedWindowId, update.windows.contains(where: { $0.id == wid }) {
                    client.send(SelectWindowMessage(windowId: wid))
                }
            }
        }

        client.onSelectWindow = { windowId in
            DispatchQueue.main.async {
                // Mac is asking us to switch — set local selection without echoing
                // a select_window back, which would loop.
                guard windows.contains(where: { $0.id == windowId }) else { return }
                selectedWindowId = windowId
            }
        }

        client.onProjectDirectories = { dirs in
            DispatchQueue.main.async {
                projectDirectories = dirs
            }
        }

        client.onError = { reason in
            DispatchQueue.main.async {
                errorToast = reason
                // Auto-dismiss after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if errorToast == reason { errorToast = nil }
                }
            }
        }

        client.onStateChange = { windowId, newState in
            DispatchQueue.main.async {
                if let i = windows.firstIndex(where: { $0.id == windowId }) {
                    let w = windows[i]
                    windows[i] = WindowState(
                        id: w.id, name: w.name, app: w.app, folder: w.folder, enabled: w.enabled,
                        frame: w.frame, state: newState, color: w.color,
                        isThinking: w.isThinking
                    )
                }
            }
        }

        volumeHandler.onSelectionChanged = { index in
            DispatchQueue.main.async {
                guard index >= 0, index < windows.count else { return }
                let newId = windows[index].id
                selectedWindowId = newId
                client.send(SelectWindowMessage(windowId: newId))
                // If viewing output, switch to the new window's content
                if terminalContentText != nil {
                    terminalContentWindowId = newId
                    client.send(RequestContentMessage(windowId: newId))
                }
            }
        }

        client.onTerminalContent = { windowId, content, screenshot in
            DispatchQueue.main.async {
                terminalContentWindowId = windowId
                terminalContentText = content
                terminalContentScreenshot = screenshot
            }
        }

        client.onOutputDelta = { windowId, windowName, text, isFinal in
            DispatchQueue.main.async {
                guard ttsEnabled else { return }
                ttsOverlayTexts[windowId] = text
            }
        }

        client.onTTSAudio = { windowId, windowName, sessionId, sequence, isFinal, wavData in
            DispatchQueue.main.async {
                guard ttsEnabled else { return }
                speech.enqueueAudio(wavData, windowId: windowId, sessionId: sessionId, isFinal: isFinal)
            }
        }

        client.onAuthRequired = {
            DispatchQueue.main.async {
                pinText = ""
                showPINEntry = true
            }
        }

        client.onAuthResult = { success, error in
            DispatchQueue.main.async {
                if success {
                    showPINEntry = false
                    pinText = ""
                }
                // On failure, PIN entry stays open — authError displayed in the UI
            }
        }

        volumeHandler.onPTTStart = {
            DispatchQueue.main.async { startRecording() }
        }

        volumeHandler.onPTTStop = {
            DispatchQueue.main.async { stopRecording() }
        }
    }

    @MainActor
    private func startRecording() {
        guard let windowId = selectedWindowId else { return }
        // Pin the windowId for this recording — stopRecording must not re-read
        // selectedWindowId, because a mid-recording select_window push or a
        // layout-update reassignment can change it underneath us.
        pttTracker.begin(windowId: windowId)
        speech.startRecording()
        isRecording = true
        // Haptic: heavy impact for recording start
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred(intensity: 1.0)
        client.send(STTStateMessage.started(windowId: windowId))
    }

    @MainActor
    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false // Set immediately to prevent re-entry from rapid presses
        // Haptic: triple heavy tap for recording stop
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred(intensity: 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            generator.impactOccurred(intensity: 1.0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            generator.impactOccurred(intensity: 1.0)
        }
        // Grab the live transcription (already visible on screen) and send immediately.
        // Then stop the recognizer — the text we saw is what we send. Trim whitespace
        // and newlines: stray trailing \n characters get typed into the terminal as
        // literal line-breaks inside Claude Code's input box, which then swallows the
        // pressReturn keystroke as "add another newline" instead of "submit".
        let text = speech.stopRecording().trimmingCharacters(in: .whitespacesAndNewlines)
        let windowId = pttTracker.end()
        NSLog("[Quip] stopRecording: windowId=%@, text='%@' (length=%d)", windowId ?? "nil", text, text.count)
        if let windowId {
            client.send(STTStateMessage.ended(windowId: windowId))
            if !text.isEmpty {
                NSLog("[Quip] Sending text to window %@", windowId)
                client.send(SendTextMessage(windowId: windowId, text: text, pressReturn: true))
            }
        }
    }
}

// MARK: - Main iOS View

struct MainiOSView: View {
    @Bindable var client: WebSocketClient
    var speech: SpeechService
    var bonjourBrowser: BonjourBrowser
    @Binding var windows: [WindowState]
    @Binding var selectedWindowId: String?
    @Binding var isRecording: Bool
    @Binding var terminalContentText: String?
    @Binding var terminalContentScreenshot: String?
    @Binding var terminalContentWindowId: String?
    @Binding var showPINEntry: Bool
    @Binding var pinText: String
    var projectDirectories: [String]
    @Binding var errorToast: String?
    var ttsOverlayTexts: [String: String]
    var monitorName: String
    var screenAspect: Double
    var onStartRecording: () -> Void
    var onStopRecording: () -> Void
    var onRequestContent: (String) -> Void

    @AppStorage("lastURL") private var urlText: String = ""
    @AppStorage("recentConnectionsData") private var recentConnectionsData: Data = Data()
    @AppStorage("ttsEnabled") private var ttsEnabled = false
    @AppStorage("enabledQuickButtons") private var enabledQuickButtonsRaw: String = "plan,backspace"
    @State private var showSettings = false
    @State private var showQRScanner = false
    @State private var showSpawnPicker = false
    @State private var recentConnections: [SavedConnection] = []
    @State private var editingConnection: SavedConnection?
    @State private var renameText: String = ""
    @State private var showTextInput = false
    @State private var textInputValue = ""
    @State private var showURLWarning = false
    @State private var pendingUnsafeURL: URL?
    // When true, the window-picker layout card collapses and InlineTerminalContent
    // expands to fill its space — gives the terminal more vertical room for reading.
    @State private var isTerminalExpanded = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var colors: QuipColors { QuipColors(scheme: colorScheme) }
    private var isPortrait: Bool { verticalSizeClass == .regular }

    var body: some View {
        ZStack {
            colors.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if !client.isConnected && !client.isConnecting {
                    connectBar
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                } else if client.isConnected && !client.isAuthenticated {
                    authenticatingBar
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                } else {
                    connectedBar
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                }

                if isPortrait && !isTerminalExpanded {
                    windowLayout
                        .aspectRatio(CGFloat(screenAspect) / 1.45, contentMode: .fit)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                } else if !isPortrait {
                    windowLayout
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                }

                if showTextInput {
                    textInputBar
                }

                if isPortrait && client.isAuthenticated && selectedWindowId != nil {
                    InlineTerminalContent(
                        content: terminalContentText ?? "",
                        screenshot: terminalContentScreenshot,
                        windowName: windows.first(where: { $0.id == selectedWindowId })?.name ?? "",
                        windowColor: windows.first(where: { $0.id == selectedWindowId }).map { Color(hex: $0.color) } ?? colors.textSecondary,
                        isExpanded: $isTerminalExpanded,
                        onRefresh: {
                            if let wid = selectedWindowId { onRequestContent(wid) }
                        },
                        onSendAction: { action in
                            if let wid = selectedWindowId {
                                client.send(QuickActionMessage(windowId: wid, action: action))
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                } else if isPortrait {
                    Spacer(minLength: 0)
                }

                if isPortrait && client.isAuthenticated && !windows.isEmpty {
                    portraitControls
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                }

                bottomBar
                    .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .overlay {
            if isRecording {
                // Full-screen tap-to-stop layer (landscape) or dimmed backdrop (portrait)
                Color.black.opacity(isPortrait ? 0.4 : 0.25)
                    .ignoresSafeArea()
                    .allowsHitTesting(!isPortrait)
                    .onTapGesture { if !isPortrait { onStopRecording() } }

                VStack(spacing: 12) {
                    Spacer()

                    // Live transcription display
                    if !speech.transcribedText.isEmpty {
                        Text(speech.transcribedText)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                            .background(.black.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                            )
                            .padding(.horizontal, 24)
                            .transition(.opacity)
                    }

                    if !isPortrait {
                        // Recording indicator pill (landscape only)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.red)
                                .frame(width: 10, height: 10)
                                .opacity(0.9)
                            Text(speech.transcribedText.isEmpty ? "Listening — tap to stop" : "Tap to send")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.35))
                        .clipShape(Capsule())
                        .padding(.bottom, 20)
                    } else {
                        // Leave space for portrait controls below
                        Spacer().frame(height: 120)
                    }
                }
                .allowsHitTesting(!isPortrait)
            }
        }
        .overlay {
            // In portrait the inline terminal view replaces this popup, so don't stack them.
            if let content = terminalContentText, !isPortrait {
                let windowName = windows.first(where: { $0.id == terminalContentWindowId })?.name ?? "Terminal"
                TerminalContentOverlay(
                    content: content,
                    screenshot: terminalContentScreenshot,
                    windowName: windowName,
                    onDismiss: {
                        terminalContentText = nil
                        terminalContentScreenshot = nil
                        terminalContentWindowId = nil
                    },
                    onRefresh: {
                        if let wid = terminalContentWindowId {
                            onRequestContent(wid)
                        }
                    },
                    onSendAction: { action in
                        if let wid = terminalContentWindowId {
                            client.send(QuickActionMessage(windowId: wid, action: action))
                        }
                    },
                    onSendText: { text in
                        if let wid = terminalContentWindowId {
                            client.send(SendTextMessage(windowId: wid, text: text, pressReturn: false))
                        }
                    }
                )
            }
        }
        .overlay {
            if speech.isSpeaking {
                TTSNotificationOverlay(
                    currentSpeakingWindowId: speech.currentSpeakingWindowId,
                    windows: windows,
                    ttsTexts: ttsOverlayTexts,
                    onTap: { windowId in
                        onRequestContent(windowId)
                    },
                    onSwipeDismiss: { speech.stopSpeaking() }
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 500)
                .padding(.horizontal, 24)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: speech.isSpeaking)
            }
        }
        .allowsHitTesting(true)
        .overlay { HiddenVolumeView().frame(width: 1, height: 1) }
        .overlay(alignment: .top) {
            if let toast = errorToast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.85))
                    .clipShape(Capsule())
                    .padding(.top, 50)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: errorToast)
            }
        }
        .environment(\.quipColors, colors)
        .onAppear { updateOrientation() }
        .onChange(of: client.isConnected) { _, connected in
            withAnimation(.easeInOut(duration: 0.5)) {
                if !connected {
                    windows = []
                    selectedWindowId = nil
                }
                updateOrientation()
            }
        }
        .onChange(of: client.isAuthenticated) { _, authenticated in
            withAnimation(.easeInOut(duration: 0.5)) {
                if !authenticated {
                    windows = []
                    selectedWindowId = nil
                }
                updateOrientation()
            }
        }
        .onChange(of: selectedWindowId) { _, newId in
            // Auto-fetch terminal output for the inline view in portrait.
            if isPortrait, let id = newId { onRequestContent(id) }
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerView { code in
                urlText = code
                showQRScanner = false
                doConnect()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(enabledQuickButtonsRaw: $enabledQuickButtonsRaw)
        }
        .alert("Unrecognized Server", isPresented: $showURLWarning) {
            Button("Connect Anyway", role: .destructive) {
                if let url = pendingUnsafeURL {
                    client.connect(to: url)
                    addToRecents(url.absoluteString)
                    pendingUnsafeURL = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingUnsafeURL = nil
            }
        } message: {
            if let url = pendingUnsafeURL {
                Text("This URL doesn't match expected patterns (local network or Cloudflare tunnel):\n\n\(url.absoluteString)\n\nConnecting to an unknown server could expose your data.")
            }
        }
    }

    // MARK: - Connect Bar (disconnected)

    private var connectBar: some View {
        VStack(spacing: 6) {
            // URL input row
            HStack(spacing: 6) {
                Circle()
                    .fill(colors.statusDisconnected)
                    .frame(width: 6, height: 6)

                TextField("wss://...", text: $urlText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(colors.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onSubmit { doConnect() }

                Button { pasteFromClipboard() } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 18))
                        .foregroundStyle(colors.textSecondary)
                        .frame(width: 36, height: 36)
                }

                Button { showQRScanner = true } label: {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 18))
                        .foregroundStyle(colors.textSecondary)
                        .frame(width: 36, height: 36)
                }

                Button { doConnect() } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(urlText.isEmpty ? colors.buttonDisabled : colors.buttonPrimary)
                }
                .disabled(urlText.isEmpty)
            }

            // Discovered on local network
            if !bonjourBrowser.discoveredHosts.isEmpty {
                VStack(spacing: 4) {
                    ForEach(bonjourBrowser.discoveredHosts) { host in
                        Button {
                            if let url = host.wsURL {
                                client.connect(to: url)
                                addToRecents(url.absoluteString)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "bonjour")
                                    .font(.system(size: 14))
                                    .foregroundStyle(colors.discoveredDot)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(colors.textPrimary.opacity(0.8))
                                    Text("\(host.host):\(host.port)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(colors.textTertiary)
                                }
                                Spacer()
                                Text("Local")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(colors.discoveredLabel)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(colors.discoveredBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            // Recent connections
            if !recentConnections.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(sortedRecents) { conn in
                            Button {
                                urlText = conn.url
                                doConnect()
                            } label: {
                                HStack(spacing: 8) {
                                    if conn.pinned {
                                        Image(systemName: "pin.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.yellow.opacity(0.6))
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(conn.displayName)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(colors.textPrimary.opacity(0.8))
                                            .lineLimit(1)
                                        Text(conn.url)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(colors.textTertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 11))
                                        .foregroundStyle(colors.textFaint)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(colors.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .contextMenu {
                                Button {
                                    togglePin(conn)
                                } label: {
                                    Label(conn.pinned ? "Unpin" : "Pin to Top", systemImage: conn.pinned ? "pin.slash" : "pin")
                                }
                                Button {
                                    editingConnection = conn
                                    renameText = conn.name ?? ""
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    deleteConnection(conn)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { loadRecents() }
        .alert("Rename Connection", isPresented: .init(
            get: { editingConnection != nil },
            set: { if !$0 { editingConnection = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let conn = editingConnection {
                    renameConnection(conn, to: renameText)
                }
                editingConnection = nil
            }
            Button("Cancel", role: .cancel) { editingConnection = nil }
        }
    }

    private var sortedRecents: [SavedConnection] {
        recentConnections.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.lastUsed > b.lastUsed
        }
    }

    // MARK: - Connected Bar

    private var connectedBar: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(client.isConnected ? colors.statusConnected : colors.statusConnecting)
                .frame(width: 6, height: 6)
            Text(client.isConnected ? "Connected" : "Connecting\u{2026}")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(colors.textSecondary)
            if let error = client.lastError {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.red.opacity(0.7))
            }
            if isRecording {
                Text("REC")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(colors.recording)
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.textTertiary)
            }
            .padding(.trailing, 6)
            Button {
                client.disconnect()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.textTertiary)
            }
        }
    }

    // MARK: - Authenticating Bar

    private var authenticatingBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle()
                    .fill(colors.statusConnecting)
                    .frame(width: 6, height: 6)
                Text("Authenticating\u{2026}")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(colors.textSecondary)
                Spacer()
                Button {
                    client.disconnect()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textTertiary)
                }
            }

            if showPINEntry {
                pinEntryView
            }
        }
    }

    private var pinEntryView: some View {
        VStack(spacing: 8) {
            Text("Enter PIN")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(colors.textPrimary)

            Text("Enter the PIN shown on your desktop app")
                .font(.system(size: 10))
                .foregroundStyle(colors.textTertiary)

            HStack(spacing: 6) {
                TextField("000000", text: $pinText)
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .foregroundStyle(colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 160)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(client.authError != nil ? Color.red.opacity(0.5) : colors.surfaceBorder, lineWidth: 1)
                    )

                Button {
                    guard pinText.count >= 4 else { return }
                    client.sendAuth(pin: pinText)
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(pinText.count >= 4 ? colors.buttonPrimary : colors.buttonDisabled)
                }
                .disabled(pinText.count < 4)
            }

            if let error = client.authError {
                Text(error)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.red.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(colors.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Portrait Controls

    private var portraitControls: some View {
        let selectedWindow = windows.first(where: { $0.id == selectedWindowId })
        let windowColor = selectedWindow.map { Color(hex: $0.color) } ?? colors.textSecondary

        return VStack(spacing: 8) {
            // Control buttons
            HStack(spacing: 6) {
                // Previous window
                Button {
                    cycleWindow(direction: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(windows.count > 1 ? colors.textPrimary : colors.textFaint)
                        .frame(width: 40, height: 56)
                        .background(colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(windows.count <= 1)

                // Next window
                Button {
                    cycleWindow(direction: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(windows.count > 1 ? colors.textPrimary : colors.textFaint)
                        .frame(width: 40, height: 56)
                        .background(colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(windows.count <= 1)

                // Spawn new window from project directory
                Button {
                    showSpawnPicker = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                        .frame(width: 40, height: 56)
                        .background(colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // Push to talk
                Button {
                    if isRecording {
                        onStopRecording()
                    } else {
                        onStartRecording()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 20))
                        Text(isRecording ? "Stop" : "Push to Talk")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .foregroundStyle(isRecording ? .white : colors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(isRecording ? Color.red.opacity(0.7) : colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // View output
                Button {
                    if let wid = selectedWindowId {
                        onRequestContent(wid)
                    }
                } label: {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(selectedWindowId != nil ? colors.textPrimary : colors.textFaint)
                        .frame(width: 56, height: 56)
                        .background(colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(selectedWindowId == nil)

                // Press Return
                Button {
                    if let wid = selectedWindowId {
                        client.send(QuickActionMessage(windowId: wid, action: "press_return"))
                    }
                } label: {
                    Image(systemName: "return")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(selectedWindowId != nil ? colors.textPrimary : colors.textFaint)
                        .frame(width: 56, height: 56)
                        .background(colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(selectedWindowId == nil)
            }

            // Secondary command-shortcut row — user-configurable via Settings.
            let enabled = QuickButton.decode(enabledQuickButtonsRaw)
            if !enabled.isEmpty {
                HStack(spacing: 5) {
                    ForEach(enabled) { button in
                        quickActionButton(button)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showSpawnPicker) {
            NavigationStack {
                Group {
                    if projectDirectories.isEmpty {
                        ContentUnavailableView(
                            "No Project Directories",
                            systemImage: "folder.badge.plus",
                            description: Text("Add directories in Quip Mac Settings → Directories tab")
                        )
                    } else {
                        List(projectDirectories, id: \.self) { dir in
                            Button {
                                client.send(SpawnWindowMessage(directory: dir))
                                showSpawnPicker = false
                            } label: {
                                Label((dir as NSString).lastPathComponent, systemImage: "folder")
                            }
                        }
                    }
                }
                .navigationTitle("New Window")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showSpawnPicker = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func cycleWindow(direction: Int) {
        guard windows.count > 1 else { return }
        let currentIndex = windows.firstIndex(where: { $0.id == selectedWindowId }) ?? 0
        let nextIndex = (currentIndex + direction + windows.count) % windows.count
        let newId = windows[nextIndex].id
        withAnimation(.spring(duration: 0.2)) {
            selectedWindowId = newId
        }
        client.send(SelectWindowMessage(windowId: newId))
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
            Spacer()
            // Version marker — only shown on tagged dev builds whose version
            // string contains a hyphen (e.g. "1.0-eb-branch"). Clean release
            // versions from main like "1.0" don't show the footer, keeping
            // production chrome uncluttered. When eb-branch merges back into
            // main and the version drops to "1.0", the footer auto-hides.
            if let rawVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               rawVersion.contains("-") {
                Text("v\(rawVersion)")
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(colors.textTertiary)
                    .padding(.trailing, 8)
            }
            if client.isAuthenticated {
                Button {
                    if speech.isSpeaking {
                        speech.stopSpeaking()
                    }
                    ttsEnabled.toggle()
                } label: {
                    Image(systemName: ttsEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(ttsEnabled ? colors.statusConnected : colors.textTertiary)
                }
                .padding(.trailing, 8)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showTextInput.toggle()
                        if !showTextInput { textInputValue = "" }
                    }
                } label: {
                    Image(systemName: showTextInput ? "keyboard.chevron.compact.down" : "keyboard")
                        .font(.system(size: 14))
                        .foregroundStyle(colors.textSecondary)
                }
            }
        }
    }

    // MARK: - Text Input Bar

    private var textInputBar: some View {
        HStack(spacing: 6) {
            TextField("Type a prompt\u{2026}", text: $textInputValue)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(colors.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onSubmit { sendTextInput() }

            Button { sendTextInput() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(textInputValue.isEmpty ? colors.buttonDisabled : colors.buttonPrimary)
            }
            .disabled(textInputValue.isEmpty)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(colors.background)
    }

    private func sendTextInput() {
        let text = textInputValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let windowId = selectedWindowId else { return }
        client.send(SendTextMessage(windowId: windowId, text: text, pressReturn: true))
        textInputValue = ""
    }

    // MARK: - Window Layout

    private var windowLayout: some View {
        GeometryReader { geo in
            let mac = hostScreenRect(in: geo.size, aspect: CGFloat(screenAspect))
            ZStack(alignment: .topLeading) {
                Color.clear

                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(colors.surface.opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(colors.surfaceBorder, lineWidth: 0.5)
                        )

                    if windows.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "macwindow.on.rectangle")
                                .font(.system(size: 24, weight: .light))
                                .foregroundStyle(colors.textFaint)
                            Text(client.isAuthenticated ? "No windows" : client.isConnected ? "Enter PIN" : "Enter tunnel URL")
                                .font(.system(size: 10))
                                .foregroundStyle(colors.textFaint)
                            if client.isAuthenticated {
                                Button {
                                    showSpawnPicker = true
                                } label: {
                                    Label("New Window", systemImage: "plus")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(Color.blue.opacity(0.7))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    } else {
                        ForEach(windows) { window in
                            let rect = windowRect(frame: window.frame, in: mac.size, inset: 3)
                            WindowRectangle(
                                window: window,
                                isSelected: window.id == selectedWindowId,
                                onSelect: {
                                    withAnimation(.spring(duration: 0.2)) {
                                        selectedWindowId = window.id
                                    }
                                    // Tell Mac to focus this window
                                    client.send(SelectWindowMessage(windowId: window.id))
                                },
                                onAction: { action in
                                    sendAction(windowId: window.id, action: action)
                                }
                            )
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                        }
                    }
                }
                .frame(width: mac.width, height: mac.height)
                .offset(x: mac.minX, y: mac.minY)
            }
        }
    }

    /// Largest rect with the given aspect ratio (width/height) that fits inside `size`, centered.
    private func hostScreenRect(in size: CGSize, aspect: CGFloat) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let available = size.width / size.height
        if available > aspect {
            let w = size.height * aspect
            return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: size.height)
        } else {
            // Portrait: stretch vertically a bit so the thumbnail isn't a narrow strip.
            let h = min(size.height, (size.width / aspect) * 1.45)
            return CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
        }
    }

    private func windowRect(frame: WindowFrame, in size: CGSize, inset: CGFloat) -> CGRect {
        let w = size.width - inset * 2
        let h = size.height - inset * 2
        return CGRect(
            x: inset + frame.x * w,
            y: inset + frame.y * h,
            width: frame.width * w,
            height: frame.height * h
        )
    }

    // MARK: - Actions

    private func doConnect() {
        guard !urlText.isEmpty else { return }
        let urlStr: String
        if urlText.hasPrefix("wss://") || urlText.hasPrefix("ws://") {
            urlStr = urlText
        } else if urlText.contains("trycloudflare.com") {
            urlStr = "wss://\(urlText)"
        } else if urlText.hasSuffix(".ts.net") || urlText.contains(".ts.net:") {
            urlStr = "ws://\(urlText)"
        } else if looksLikeTailscaleCGNAT(urlText) {
            urlStr = "ws://\(urlText)"
        } else if urlText.contains(":") {
            urlStr = "ws://\(urlText)"
        } else {
            urlStr = "wss://\(urlText)"
        }
        if let url = URL(string: urlStr) {
            if isURLTrusted(url) {
                client.connect(to: url)
                addToRecents(urlStr)
            } else {
                pendingUnsafeURL = url
                showURLWarning = true
            }
        }
    }

    private func isURLTrusted(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let scheme = url.scheme?.lowercased() ?? ""

        // wss:// to *.trycloudflare.com is trusted
        if scheme == "wss" && (host == "trycloudflare.com" || host.hasSuffix(".trycloudflare.com")) {
            return true
        }

        // ws:// to local/private IPs and Tailscale targets is trusted
        if scheme == "ws" {
            if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }

            // Tailscale MagicDNS hostnames (e.g. quip-mac.tail1234.ts.net)
            if host.hasSuffix(".ts.net") { return true }

            // RFC 1918 private ranges + Tailscale CGNAT 100.64.0.0/10
            let parts = host.split(separator: ".").compactMap { UInt8($0) }
            if parts.count == 4 {
                if parts[0] == 10 { return true }                                    // 10.0.0.0/8
                if parts[0] == 172 && (16...31).contains(parts[1]) { return true }   // 172.16.0.0/12
                if parts[0] == 192 && parts[1] == 168 { return true }               // 192.168.0.0/16
                if parts[0] == 169 && parts[1] == 254 { return true }               // 169.254.0.0/16 link-local
                if parts[0] == 100 && (64...127).contains(parts[1]) { return true } // 100.64.0.0/10 Tailscale CGNAT
            }
            return false
        }

        return false
    }

    /// True if `raw` starts with a 100.64–127.x.x address (Tailscale CGNAT range).
    /// Accepts optional port suffix.
    private func looksLikeTailscaleCGNAT(_ raw: String) -> Bool {
        let hostPart = raw.split(separator: ":").first.map(String.init) ?? raw
        let parts = hostPart.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    // MARK: - Recent Connections

    private func loadRecents() {
        if let decoded = try? JSONDecoder().decode([SavedConnection].self, from: recentConnectionsData) {
            recentConnections = decoded
        }
    }

    private func saveRecents() {
        if let encoded = try? JSONEncoder().encode(recentConnections) {
            recentConnectionsData = encoded
        }
    }

    private static let maxConnections = 10

    private func addToRecents(_ url: String) {
        if let i = recentConnections.firstIndex(where: { $0.url == url }) {
            recentConnections[i].lastUsed = Date()
        } else {
            recentConnections.append(SavedConnection(url: url))
        }
        // Keep max 10 total: all pinned + newest unpinned to fill remaining slots
        let pinned = recentConnections.filter(\.pinned)
        let unpinned = recentConnections.filter { !$0.pinned }.sorted { $0.lastUsed > $1.lastUsed }
        let unpinnedLimit = max(0, Self.maxConnections - pinned.count)
        recentConnections = pinned + Array(unpinned.prefix(unpinnedLimit))
        saveRecents()
    }

    private func togglePin(_ conn: SavedConnection) {
        if let i = recentConnections.firstIndex(where: { $0.id == conn.id }) {
            recentConnections[i].pinned.toggle()
            saveRecents()
        }
    }

    private func renameConnection(_ conn: SavedConnection, to name: String) {
        if let i = recentConnections.firstIndex(where: { $0.id == conn.id }) {
            recentConnections[i].name = name.isEmpty ? nil : name
            saveRecents()
        }
    }

    private func deleteConnection(_ conn: SavedConnection) {
        recentConnections.removeAll { $0.id == conn.id }
        saveRecents()
    }

    private func updateOrientation() {
        AppOrientationDelegate.allowAllOrientations = client.isAuthenticated
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        if !client.isAuthenticated {
            // Lock to portrait when disconnected
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
        // When authenticated, allow free rotation — don't force any specific orientation
        UIViewController.attemptRotationToDeviceOrientation()
    }

    private func pasteFromClipboard() {
        if let str = UIPasteboard.general.string, !str.isEmpty {
            urlText = str
        }
    }

    private func sendAction(windowId: String, action: WindowAction) {
        if action == .viewOutput {
            onRequestContent(windowId)
            return
        }
        // Duplicate and closeWindow send different message types than
        // QuickActionMessage, so they're early-return branches.
        if action == .duplicate {
            client.send(DuplicateWindowMessage(sourceWindowId: windowId))
            return
        }
        if action == .closeWindow {
            client.send(CloseWindowMessage(windowId: windowId))
            return
        }
        let str: String
        switch action {
        case .pressReturn: str = "press_return"
        case .cancel: str = "press_ctrl_c"
        case .clearTerminal: str = "clear_terminal"
        case .restartClaude: str = "restart_claude"
        case .toggleEnabled: str = "toggle_enabled"
        case .viewOutput: return // handled above
        case .duplicate: return  // handled above
        case .closeWindow: return // handled above
        }
        client.send(QuickActionMessage(windowId: windowId, action: str))
    }

    // MARK: - Configurable Quick Buttons

    @ViewBuilder
    private func quickActionButton(_ button: QuickButton) -> some View {
        Button {
            guard let wid = selectedWindowId else { return }
            switch button.action {
            case .sendText(let text, let pressReturn):
                client.send(SendTextMessage(windowId: wid, text: text, pressReturn: pressReturn))
            case .quickAction(let action):
                client.send(QuickActionMessage(windowId: wid, action: action))
            }
        } label: {
            Group {
                if let symbol = button.systemImage {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                } else {
                    Text(button.label)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundStyle(.white.opacity(selectedWindowId != nil ? 0.9 : 0.35))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .disabled(selectedWindowId == nil)
    }
}

// MARK: - QR Scanner

struct QRScannerView: View {
    var onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                // Simple camera-based QR reader using AVFoundation
                QRCameraView(onScan: onScan)
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// AVFoundation QR scanner
struct QRCameraView: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let vc = QRScannerController()
        vc.onScan = onScan
        return vc
    }
    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
}

class QRScannerController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    private var captureSession: AVCaptureSession?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)

        captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasScanned,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let str = obj.stringValue else { return }
        hasScanned = true
        captureSession?.stopRunning()
        onScan?(str)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let layer = view.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            layer.frame = view.bounds
        }
    }
}

// MARK: - Saved Connection Model

struct SavedConnection: Codable, Identifiable {
    var id = UUID()
    var url: String
    var name: String?
    var pinned: Bool = false
    var lastUsed: Date = Date()

    var displayName: String {
        if let name, !name.isEmpty { return name }
        // Extract hostname from URL
        if let u = URL(string: url), let host = u.host {
            let short = host.replacingOccurrences(of: ".trycloudflare.com", with: "")
            return short
        }
        return url
    }
}

// MARK: - Inline Terminal Content (portrait mode)

struct InlineTerminalContent: View {
    let content: String
    let screenshot: String?
    let windowName: String
    let windowColor: Color
    @Binding var isExpanded: Bool
    var onRefresh: () -> Void
    var onSendAction: (String) -> Void
    @Environment(\.quipColors) private var colors
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(windowColor)
                    .frame(width: 8, height: 8)
                Text(windowName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.8))
                Spacer()
                // Expand / collapse — hides the window-picker card above to
                // give the terminal more vertical real estate. Tap again to
                // bring the picker back. Compact: single icon button, reuses
                // the same row, reversible state.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                Button { onRefresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06))

            ScrollViewReader { proxy in
                ScrollView {
                    if let screenshot, let imageData = Data(base64Encoded: screenshot),
                       let uiImage = UIImage(data: imageData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .id("bottom")
                    } else if !content.isEmpty {
                        Text(content)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .textSelection(.enabled)
                            .id("bottom")
                    } else {
                        Text("Loading…")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .id("bottom")
                    }
                }
                .onChange(of: content) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 5) {
                keyButton("Return", icon: "return") { onSendAction("press_return") }
                keyButton("Ctrl+C", icon: "xmark.octagon") { onSendAction("press_ctrl_c") }
                keyButton("Ctrl+D", icon: "eject") { onSendAction("press_ctrl_d") }
                keyButton("Esc", icon: "escape") { onSendAction("press_escape") }
                keyButton("Tab", icon: "arrow.right.to.line") { onSendAction("press_tab") }
                keyButton("Y", icon: nil) { onSendAction("press_y") }
                keyButton("N", icon: nil) { onSendAction("press_n") }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06))
        }
        .background(colors.overlayContainer)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear { onRefresh() }
        .onReceive(refreshTimer) { _ in onRefresh() }
    }

    private func keyButton(_ label: String, icon: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                }
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

// MARK: - Quick Button Config

enum QuickButton: String, CaseIterable, Identifiable {
    case plan, btw, backspace, clearContext, one, two, three

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plan: return "/plan"
        case .btw: return "/btw"
        case .backspace: return "Backspace"
        case .clearContext: return "Clear context (/clear)"
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        }
    }

    var label: String {
        switch self {
        case .plan: return "/plan"
        case .btw: return "/btw"
        case .backspace: return ""
        case .clearContext: return "/clear"
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        }
    }

    var systemImage: String? {
        self == .backspace ? "delete.left" : nil
    }

    enum Action {
        case sendText(String, pressReturn: Bool)
        case quickAction(String)
    }

    var action: Action {
        switch self {
        case .plan: return .sendText("/plan ", pressReturn: false)
        case .btw: return .sendText("/btw ", pressReturn: false)
        case .backspace: return .quickAction("press_backspace")
        case .clearContext: return .sendText("/clear", pressReturn: true)
        case .one: return .sendText("1", pressReturn: true)
        case .two: return .sendText("2", pressReturn: true)
        case .three: return .sendText("3", pressReturn: true)
        }
    }

    static func decode(_ raw: String) -> [QuickButton] {
        raw.split(separator: ",").compactMap { QuickButton(rawValue: String($0)) }
    }

    static func encode(_ buttons: [QuickButton]) -> String {
        buttons.map(\.rawValue).joined(separator: ",")
    }
}

// MARK: - Settings Sheet

struct SettingsSheet: View {
    @Binding var enabledQuickButtonsRaw: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(QuickButton.allCases) { button in
                        Toggle(button.displayName, isOn: binding(for: button))
                    }
                } header: {
                    Text("Quick Buttons")
                } footer: {
                    Text("Shown in the compact row under the main shortcuts. Order matches the list above.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func binding(for button: QuickButton) -> Binding<Bool> {
        Binding(
            get: { QuickButton.decode(enabledQuickButtonsRaw).contains(button) },
            set: { isOn in
                var current = QuickButton.decode(enabledQuickButtonsRaw)
                if isOn {
                    if !current.contains(button) {
                        // Insert in canonical order (matches allCases) so the row
                        // stays stable regardless of toggle sequence.
                        current = QuickButton.allCases.filter { current.contains($0) || $0 == button }
                    }
                } else {
                    current.removeAll { $0 == button }
                }
                enabledQuickButtonsRaw = QuickButton.encode(current)
            }
        )
    }
}
