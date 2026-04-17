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
    // Text input bar state owned here so PTT can drop the voice
    // transcription into the field for review instead of auto-sending.
    @State private var showTextInput = false
    @State private var textInputValue = ""
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
                showTextInput: $showTextInput,
                textInputValue: $textInputValue,
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
        // Type the transcription straight into Claude Code's `>` prompt on
        // the Mac — `pressReturn: false` keeps it in the input line rather
        // than submitting, so a long dictation shows up verbatim in the
        // terminal (and thus in the phone's content panel via the next
        // refresh). User hits Return when they're ready.
        //
        // Trim trailing whitespace/newlines: a stray \n typed into Claude's
        // box would get swallowed by the box as a newline rather than
        // treated as "submit," and it breaks the render.
        let text = speech.stopRecording().trimmingCharacters(in: .whitespacesAndNewlines)
        let windowId = pttTracker.end()
        NSLog("[Quip] stopRecording: windowId=%@, text='%@' (length=%d)", windowId ?? "nil", text, text.count)
        if let windowId {
            client.send(STTStateMessage.ended(windowId: windowId))
            if !text.isEmpty {
                client.send(SendTextMessage(windowId: windowId, text: text, pressReturn: false))
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
    @Binding var showTextInput: Bool
    @Binding var textInputValue: String
    var onStartRecording: () -> Void
    var onStopRecording: () -> Void
    var onRequestContent: (String) -> Void

    @AppStorage("lastURL") private var urlText: String = ""
    @AppStorage("recentConnectionsData") private var recentConnectionsData: Data = Data()
    @AppStorage("ttsEnabled") private var ttsEnabled = false
    // Default covers the most common Claude Code interactions: one slash
    // command, the Y/N confirmations that Claude asks for, Esc to dismiss,
    // and Ctrl+C to abort. Everything else is opt-in from Settings.
    @AppStorage("enabledQuickButtons") private var enabledQuickButtonsRaw: String = "plan,yes,no,esc,ctrlC"
    @State private var showSettings = false
    @State private var showQRScanner = false
    @State private var showSpawnPicker = false
    @State private var recentConnections: [SavedConnection] = []
    @State private var editingConnection: SavedConnection?
    @State private var renameText: String = ""
    @State private var showURLWarning = false
    @State private var pendingUnsafeURL: URL?
    @State private var testState: ConnectionTestState = .idle
    @State private var testResultAutoDismiss: Task<Void, Never>?
    /// Which layout the next tap on the arrange button will send. The icon
    /// shown on the button reflects this so the user can predict the outcome.
    /// Phone-only display layout for window rectangles. `nil` = show whatever
    /// layout the Mac reports; `"horizontal"` = columns side-by-side on the
    /// phone; `"vertical"` = rows top-to-bottom. **Does not** touch the
    /// Mac's actual window positions — just reorganizes the preview here.
    @State private var phoneLayoutOverride: String? = nil
    // When true, the window-picker layout card collapses and InlineTerminalContent
    // expands to fill its space — gives the terminal more vertical room for reading.
    @State private var isTerminalExpanded = false
    // Draggable split between windowLayout (top) and InlineTerminalContent (bottom).
    // Stored as the terminal's share of the split area; clamped to [0.1, 0.9] so
    // the windowLayout can't be squeezed to zero and the terminal can't take 100%
    // (the isTerminalExpanded toggle is the explicit way to hide the windows).
    @AppStorage("terminalHeightFraction") private var terminalHeightFraction: Double = 0.6
    @GestureState private var dragFractionDelta: Double = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var colors: QuipColors { QuipColors(scheme: colorScheme) }
    private var isPortrait: Bool { verticalSizeClass == .regular }

    // Pending image attachment — shared between portrait and landscape input rows.
    @StateObject private var pendingImage = PendingImageState()
    @State private var showingImageSourceSheet = false
    @State private var showingLibraryPicker = false
    @State private var showingCameraPicker = false

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

                if isPortrait {
                    portraitContentSection
                } else {
                    windowLayout
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                    if showTextInput {
                        textInputBar
                    }
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
                            // press_return is the "submit" action — flush a queued image
                            // first so landscape mirrors the portrait Return behavior.
                            if action == "press_return" {
                                sendPendingImageIfNeeded(windowId: wid)
                            }
                            client.send(QuickActionMessage(windowId: wid, action: action))
                        }
                    },
                    onSendText: { text in
                        if let wid = terminalContentWindowId {
                            sendPendingImageIfNeeded(windowId: wid)
                            if !text.isEmpty {
                                client.send(SendTextMessage(windowId: wid, text: text, pressReturn: false))
                            }
                        }
                    },
                    onAttachImage: {
                        showingImageSourceSheet = true
                    }
                )
                .environmentObject(pendingImage)
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
        .onAppear {
            updateOrientation()
            // Register image upload result callbacks. These are idempotent
            // reassignments so re-firing onAppear is harmless.
            client.onImageUploadAck = { [weak pendingImage] _ in
                DispatchQueue.main.async { pendingImage?.clear() }
            }
            client.onImageUploadError = { [weak pendingImage] reason in
                DispatchQueue.main.async { pendingImage?.markError(reason) }
            }
        }
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
            // Wipe the cached terminal content immediately so the inline view
            // shows "Loading…" instead of the previous window's text while
            // the new window's fresh content is being fetched. Without this,
            // users would see stale output from the last window and quick
            // action buttons looked like they hit the wrong one.
            terminalContentText = nil
            terminalContentScreenshot = nil
            terminalContentWindowId = newId
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
        // Image-attach sheets — hoisted to the body so both portrait and
        // landscape views can trigger them via the shared @State bindings.
        .confirmationDialog("Attach image", isPresented: $showingImageSourceSheet, titleVisibility: .hidden) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") { showingCameraPicker = true }
            }
            Button("Choose from Library") { showingLibraryPicker = true }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingLibraryPicker) {
            LibraryImagePicker(
                onPicked: { image, mime, name in
                    pendingImage.setPending(image: image, mimeType: mime, filename: name)
                    showingLibraryPicker = false
                },
                onCancel: { showingLibraryPicker = false }
            )
        }
        .fullScreenCover(isPresented: $showingCameraPicker) {
            CameraImagePicker(
                onPicked: { image, mime, name in
                    pendingImage.setPending(image: image, mimeType: mime, filename: name)
                    showingCameraPicker = false
                },
                onCancel: { showingCameraPicker = false }
            )
        }
        .sheet(isPresented: $showSpawnPicker) {
            // Sheet lives on the outer body (not portraitControls) because the
            // "New Window" button on the empty-state view is reachable even
            // when windows are empty — at which point portraitControls is
            // hidden and a sheet scoped there can't present.
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

                // Test-connection probe. Fires a one-off WebSocket handshake
                // against whatever URL is typed and reports reachable/not, so
                // the user can tell "wrong URL" apart from "Mac offline" apart
                // from "firewall blocking" without having to commit to a full
                // connect + auth flow first.
                Button { runConnectionTest() } label: {
                    ZStack {
                        switch testState {
                        case .testing:
                            ProgressView().controlSize(.small)
                        case .success:
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.green)
                        case .failed:
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.red)
                        case .idle:
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 18))
                                .foregroundStyle(colors.textSecondary)
                        }
                    }
                    .frame(width: 36, height: 36)
                }
                .disabled(urlText.isEmpty || testState.isTesting)

                Button { doConnect() } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(urlText.isEmpty ? colors.buttonDisabled : colors.buttonPrimary)
                }
                .disabled(urlText.isEmpty)
            }

            if let msg = testState.resultMessage {
                Text(msg)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(testState.isSuccess ? Color.green : Color.red)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (testState.isSuccess ? Color.green : Color.red)
                            .opacity(0.12)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
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
                    .frame(width: 20, height: 20)
            }
            Button {
                client.disconnect()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.textTertiary)
                    .frame(width: 20, height: 20)
            }
            .padding(.trailing, 4)
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
                        .frame(width: 20, height: 20)
                }
                .padding(.trailing, 4)
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
            // Pending image thumbnail — only takes space when an image is attached.
            PendingImagePreviewStrip(state: pendingImage)

            // Control buttons
            HStack(spacing: 6) {
                // Previous window — slimmer than the main input buttons so
                // the PTT/keyboard/Return trio visually dominates the row.
                Button {
                    cycleWindow(direction: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(windows.count > 1 ? colors.textPrimary : colors.textFaint)
                        .frame(width: 30, height: 40)
                        .background(colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(windows.count <= 1)

                // Next window
                Button {
                    cycleWindow(direction: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(windows.count > 1 ? colors.textPrimary : colors.textFaint)
                        .frame(width: 30, height: 40)
                        .background(colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
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

                // Arrange — phone-only display toggle. Cycles through
                // Mac-layout (default, shows real Mac positions), columns
                // (side-by-side on phone), rows (stacked on phone). Does
                // NOT move windows on the Mac; just reorganizes the preview
                // here so overlapping/off-screen windows become distinct
                // cards when you need 'em.
                Button {
                    switch phoneLayoutOverride {
                    case nil: phoneLayoutOverride = "horizontal"
                    case "horizontal": phoneLayoutOverride = "vertical"
                    default: phoneLayoutOverride = nil
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    let icon: String = {
                        switch phoneLayoutOverride {
                        case "horizontal": return "rectangle.split.3x1"
                        case "vertical": return "rectangle.split.1x3"
                        default: return "rectangle.3.group"
                        }
                    }()
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(windows.count >= 2 ? colors.textPrimary : colors.textFaint)
                        .frame(width: 40, height: 56)
                        .background(colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(windows.filter(\.enabled).count < 2)

                // Push to talk — icon-only. Red mic when idle; when live, the
                // pill keeps its surface fill but gains a red stroke so it
                // reads as "recording" without scorching the eyeballs with a
                // solid-red rectangle. Icon switches to a red stop square.
                // Symmetric spacers pin the mic to geometric center of the
                // row regardless of how many buttons sit on either side.
                Spacer()
                Button {
                    if isRecording {
                        onStopRecording()
                    } else {
                        onStartRecording()
                    }
                } label: {
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.75))
                        .frame(width: 72, height: 56)
                        .background(colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.red.opacity(0.7), lineWidth: isRecording ? 2 : 0)
                        )
                }
                Spacer()

                // Type — toggles the text input bar above the terminal
                // content. Replaces the old "view output" icon, which became
                // redundant once content auto-refreshes on selection change
                // and after every quick action. The keyboard icon was also
                // in the bottom bar but easy to miss; putting it in the main
                // row alongside PTT/Return makes typing as reachable as
                // talking or pressing enter.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showTextInput.toggle()
                        if !showTextInput { textInputValue = "" }
                    }
                } label: {
                    Image(systemName: showTextInput ? "keyboard.chevron.compact.down" : "keyboard")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(colors.textPrimary)
                        .frame(width: 56, height: 56)
                        .background(colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // Attach image — tapping opens source picker (library / camera).
                Button {
                    showingImageSourceSheet = true
                } label: {
                    Image(systemName: pendingImage.hasPendingImage ? "photo.fill" : "photo")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(pendingImage.hasPendingImage ? colors.buttonPrimary : colors.textPrimary)
                        .frame(width: 56, height: 56)
                        .background(colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("Attach image")

                // Press Return — flushes any pending image first so a pick-then-tap-Return
                // flow actually submits the image instead of leaving the thumbnail stuck.
                Button {
                    if let wid = selectedWindowId {
                        sendPendingImageIfNeeded(windowId: wid)
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
                    ForEach(Array(enabled.enumerated()), id: \.element.id) { index, button in
                        if index > 0, enabled[index - 1].isSlashCommand != button.isSlashCommand {
                            Spacer().frame(width: 10)
                        }
                        quickActionButton(button)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 8)
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
        guard let windowId = selectedWindowId else { return }
        // An image-only submit is valid — only bail if both text AND image are empty.
        guard !text.isEmpty || pendingImage.hasPendingImage else { return }
        // Ship the image first (fire-and-forget); the Mac queues messages in order.
        sendPendingImageIfNeeded(windowId: windowId)
        if !text.isEmpty {
            client.send(SendTextMessage(windowId: windowId, text: text, pressReturn: true))
        }
        textInputValue = ""
    }

    // MARK: - Image Upload

    private let imageRecompressor = ImageRecompressor(maxPayloadBytes: 7_300_000)

    @MainActor
    private func sendPendingImageIfNeeded(windowId: String) {
        guard let image = pendingImage.image,
              let filename = pendingImage.filename,
              let mime = pendingImage.mimeType else { return }

        pendingImage.markUploading()

        // Capture value types so the closure doesn't hold a reference to self.
        let recompressor = imageRecompressor
        let clientRef = client

        DispatchQueue.global(qos: .userInitiated).async {
            let rawData: Data?
            if mime == "image/png" {
                rawData = image.pngData()
            } else {
                rawData = image.jpegData(compressionQuality: 0.95)
            }
            guard let rawData else {
                DispatchQueue.main.async { [weak pendingImage] in
                    pendingImage?.markError("couldn't encode image")
                }
                return
            }
            do {
                let (data, finalMime) = try recompressor.recompress(rawData: rawData, declaredMime: mime)
                let base64 = data.base64EncodedString()
                let msg = ImageUploadMessage(
                    imageId: UUID().uuidString,
                    windowId: windowId,
                    filename: filename,
                    mimeType: finalMime,
                    data: base64
                )
                DispatchQueue.main.async {
                    clientRef.send(msg)
                }
            } catch {
                DispatchQueue.main.async { [weak pendingImage] in
                    pendingImage?.markError("image too large to send")
                }
            }
        }
    }

    // MARK: - Portrait Split

    /// Live fraction of the split area given to the terminal, factoring in
    /// any in-progress drag. `dragFractionDelta` is a @GestureState that
    /// resets to 0 once the drag ends — at that point `onEnded` has already
    /// committed the new value into @AppStorage, so reads stay stable.
    private var resolvedTerminalFraction: Double {
        min(0.9, max(0.1, terminalHeightFraction - dragFractionDelta))
    }

    @ViewBuilder
    private var portraitContentSection: some View {
        let hasTerminal = client.isAuthenticated && selectedWindowId != nil
        if hasTerminal {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    if !isTerminalExpanded {
                        windowLayout
                            .frame(height: geo.size.height * (1 - resolvedTerminalFraction))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                        resizeHandle(containerHeight: geo.size.height)
                    }
                    if showTextInput {
                        textInputBar
                    }
                    terminalContentView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                }
            }
        } else {
            windowLayout
                .aspectRatio(CGFloat(screenAspect) / 1.45, contentMode: .fit)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            if showTextInput {
                textInputBar
            }
            Spacer(minLength: 0)
        }
    }

    private var terminalContentView: some View {
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
                    // 300ms is enough for the keystroke to reach iTerm and
                    // for Claude to render its first byte; asking sooner
                    // mostly captures the pre-action state. The Mac throttle
                    // (500ms per window) still protects against floods.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        client.send(RequestContentMessage(windowId: wid))
                    }
                }
            }
        )
    }

    /// Drag-to-resize handle between windowLayout and the terminal. A full-
    /// row hairline reads as a divider; a brighter centered capsule is the
    /// grip. The 20pt vertical padding makes the whole strip tappable.
    private func resizeHandle(containerHeight: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 0.5)
                .frame(maxWidth: .infinity)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.5))
                .frame(width: 44, height: 4)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .updating($dragFractionDelta) { value, state, _ in
                    state = containerHeight > 0 ? Double(value.translation.height) / Double(containerHeight) : 0
                }
                .onEnded { value in
                    guard containerHeight > 0 else { return }
                    let delta = Double(value.translation.height) / Double(containerHeight)
                    terminalHeightFraction = min(0.9, max(0.1, terminalHeightFraction - delta))
                }
        )
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
                        ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                            let effectiveFrame = phoneLayoutFrame(for: window, index: index, total: windows.count) ?? window.frame
                            let rect = windowRect(frame: effectiveFrame, in: mac.size, inset: 3)
                            WindowRectangle(
                                window: window,
                                isSelected: window.id == selectedWindowId,
                                onSelect: {
                                    // Tapping a disabled window (which the mirror-desktop
                                    // mode surfaces) immediately enables it — that's the
                                    // whole point of seeing dimmed cards. An enabled tap
                                    // just selects + focuses.
                                    if !window.enabled {
                                        client.send(QuickActionMessage(windowId: window.id, action: "toggle_enabled"))
                                    }
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

    /// Phone-only override frame when the user has toggled the arrange
    /// button — lays out windows as clean columns or rows on the phone
    /// preview without touching the Mac. Returns `nil` when the Mac's real
    /// layout should be used.
    private func phoneLayoutFrame(for window: WindowState, index: Int, total: Int) -> WindowFrame? {
        guard let mode = phoneLayoutOverride, total > 0 else { return nil }
        switch mode {
        case "horizontal":
            let w = 1.0 / Double(total)
            return WindowFrame(x: Double(index) * w, y: 0, width: w, height: 1.0)
        case "vertical":
            let h = 1.0 / Double(total)
            return WindowFrame(x: 0, y: Double(index) * h, width: 1.0, height: h)
        default:
            return nil
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

    // MARK: - Connection Test

    /// Fires a short-lived WebSocket handshake against the typed URL and
    /// reports reachable / not-reachable / handshake-error. Kept deliberately
    /// separate from the real `doConnect` — this one never touches `client`,
    /// never saves the URL, never prompts for PIN. It's a network probe.
    private func runConnectionTest() {
        let typed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        let urlStr = normalizeConnectURL(typed)
        guard let url = URL(string: urlStr) else {
            setTestResult(.failed("Bad URL: \(urlStr)"))
            return
        }
        testResultAutoDismiss?.cancel()
        testState = .testing
        Task {
            let errMsg: String?
            do {
                try await probeWebSocket(url: url, timeout: 5)
                errMsg = nil
            } catch let err as ConnectionProbeError {
                switch err {
                case .timeout(let secs):
                    errMsg = "Timeout after \(Int(secs))s"
                }
            } catch {
                errMsg = error.localizedDescription
            }
            await MainActor.run {
                if let msg = errMsg {
                    setTestResult(.failed("\(urlStr) — \(msg)"))
                } else {
                    setTestResult(.success("Reachable: \(urlStr)"))
                }
            }
        }
    }

    private func setTestResult(_ newState: ConnectionTestState) {
        testState = newState
        // Auto-dismiss the inline status pill after 12s so it doesn't pile up
        // next to the URL field forever. The user can re-test to see again.
        testResultAutoDismiss?.cancel()
        testResultAutoDismiss = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if !Task.isCancelled {
                testState = .idle
            }
        }
    }

    private func normalizeConnectURL(_ typed: String) -> String {
        if typed.hasPrefix("wss://") || typed.hasPrefix("ws://") {
            return typed
        } else if typed.contains("trycloudflare.com") {
            return "wss://\(typed)"
        } else if typed.hasSuffix(".ts.net") || typed.contains(".ts.net:") {
            return "ws://\(typed)"
        } else if looksLikeTailscaleCGNAT(typed) {
            return "ws://\(typed)"
        } else if typed.contains(":") {
            return "ws://\(typed)"
        }
        return "wss://\(typed)"
    }

    /// Open a WebSocket task, wait up to `timeout` seconds for the first
    /// frame from the server (Quip's auth-required signal), then tear it
    /// down. Any error along the way counts as failure. Does not save or
    /// send any app-level messages.
    private nonisolated func probeWebSocket(url: URL, timeout: TimeInterval) async throws {
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await task.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ConnectionProbeError.timeout(timeout)
            }
            try await group.next()
            group.cancelAll()
        }
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
                // Auto-submitting text is a "submit" — flush any pending image first.
                if pressReturn { sendPendingImageIfNeeded(windowId: wid) }
                client.send(SendTextMessage(windowId: wid, text: text, pressReturn: pressReturn))
            case .quickAction(let action):
                if action == "press_return" { sendPendingImageIfNeeded(windowId: wid) }
                client.send(QuickActionMessage(windowId: wid, action: action))
            }
        } label: {
            Group {
                if let symbol = button.systemImage {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                } else {
                    // Single-line with auto-shrink so a row of 8-10 buttons
                    // fits on the phone without `/compact` wrapping to two
                    // lines mid-word.
                    Text(button.label)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                }
            }
            .foregroundStyle(.white.opacity(selectedWindowId != nil ? 0.9 : 0.35))
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .frame(minWidth: 26)
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
    @AppStorage("tintContentBorder") private var tintContentBorder = true
    /// Zoom level index into `ContentZoomLevel.allCases`. Persisted so the
    /// user's pick survives relaunch, and shared between portrait and
    /// landscape views so cycling in one affects both.
    @AppStorage("contentZoomLevel") private var contentZoomLevel = 1
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
                // Text-size cycler — taps through the three zoom presets so
                // you can trade panel fill for more terminal content on
                // screen at once. Icon's the A+/A− "text size" symbol.
                Button {
                    contentZoomLevel = ContentZoomLevel.from(raw: contentZoomLevel).next
                } label: {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
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
                        let zoom = ContentZoomLevel.from(raw: contentZoomLevel)
                        // Spacer-based margin instead of .padding: the previous
                        // two-frame + padding approach got collapsed by ScrollView's
                        // layout pass, leaving the screenshot edge-to-edge. Spacers
                        // guarantee a visible gutter even at fill zoom.
                        HStack(spacing: 0) {
                            Spacer(minLength: 20)
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: UIScreen.main.bounds.width * zoom.widthFraction)
                            Spacer(minLength: 20)
                        }
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
        }
        .background(colors.overlayContainer)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // Tinted border in the selected window's palette color so the
        // content panel visually ties back to the rectangle above it — easy
        // to tell at a glance which window you're driving, especially when
        // more than one window is on the picker. Controlled by a Settings
        // toggle; `.clear` hides it without shifting any layout.
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    tintContentBorder ? windowColor.opacity(0.7) : Color.clear,
                    lineWidth: 1.5
                )
        )
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
    // Declaration order matters — `allCases` uses it to render the settings
    // list and the enabled row on the phone. Grouped:
    //   Slash commands (sends "/foo"),
    //   Claude Code answers (Y/N and number choices),
    //   Terminal keystrokes (Esc, Ctrl-C, Ctrl-D, Tab, Backspace).
    case plan, btw, compact, clearContext
    case yes, no, one, two, three
    case esc, ctrlC, ctrlD, tab, backspace

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plan: return "/plan"
        case .btw: return "/btw"
        case .compact: return "/compact"
        case .clearContext: return "Clear context (/clear)"
        case .yes: return "Y"
        case .no: return "N"
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        case .esc: return "Esc"
        case .ctrlC: return "Ctrl+C"
        case .ctrlD: return "Ctrl+D"
        case .tab: return "Tab"
        case .backspace: return "Backspace"
        }
    }

    /// Short label shown in the on-screen button itself (vs. `displayName`
    /// which shows in Settings).
    var label: String {
        switch self {
        case .plan: return "/plan"
        case .btw: return "/btw"
        case .compact: return "/compact"
        case .clearContext: return "/clear"
        case .yes: return "Y"
        case .no: return "N"
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        case .esc: return "Esc"
        case .ctrlC: return "Ctrl+C"
        case .ctrlD: return "Ctrl+D"
        case .tab: return "Tab"
        case .backspace: return ""
        }
    }

    var systemImage: String? {
        switch self {
        case .backspace: return "delete.left"
        case .esc: return "escape"
        case .ctrlC: return "xmark.octagon"
        case .ctrlD: return "eject"
        case .tab: return "arrow.right.to.line"
        default: return nil
        }
    }

    enum Action {
        case sendText(String, pressReturn: Bool)
        case quickAction(String)
    }

    var isSlashCommand: Bool {
        if case .sendText(let text, _) = action { return text.hasPrefix("/") }
        return false
    }

    var action: Action {
        switch self {
        case .plan: return .sendText("/plan ", pressReturn: false)
        case .btw: return .sendText("/btw ", pressReturn: false)
        // /compact auto-submits because unlike /plan or /btw it doesn't
        // take a follow-up argument — it's a standalone command that
        // tells Claude "summarize the context now."
        case .compact: return .sendText("/compact", pressReturn: true)
        case .clearContext: return .sendText("/clear", pressReturn: true)
        case .yes: return .quickAction("press_y")
        case .no: return .quickAction("press_n")
        case .one: return .sendText("1", pressReturn: true)
        case .two: return .sendText("2", pressReturn: true)
        case .three: return .sendText("3", pressReturn: true)
        case .esc: return .quickAction("press_escape")
        case .ctrlC: return .quickAction("press_ctrl_c")
        case .ctrlD: return .quickAction("press_ctrl_d")
        case .tab: return .quickAction("press_tab")
        case .backspace: return .quickAction("press_backspace")
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
    @AppStorage("tintContentBorder") private var tintContentBorder = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Appearance — single-row section; footer goes away once the
                // feature's self-explanatory so the page stops feeling padded.
                Section("Appearance") {
                    Toggle("Tint content panel border", isOn: $tintContentBorder)
                }

                // Quick Buttons — multi-column grid of chip toggles instead
                // of the one-toggle-per-row Form layout. Fits 2-3x the
                // settings on screen at once, which matters once the enum
                // starts pushing a dozen options.
                Section("Quick Buttons") {
                    let columns = [GridItem(.adaptive(minimum: 100, maximum: 180), spacing: 6)]
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                        ForEach(QuickButton.allCases) { button in
                            quickButtonChip(button)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 0)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Tappable chip for a QuickButton — lit when enabled, dim when off.
    /// Dense enough that ~a dozen fit in the same space one Form row used
    /// to take.
    @ViewBuilder
    private func quickButtonChip(_ button: QuickButton) -> some View {
        let isOn = QuickButton.decode(enabledQuickButtonsRaw).contains(button)
        Button {
            toggle(button)
        } label: {
            HStack(spacing: 4) {
                if let icon = button.systemImage {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                }
                Text(button.displayName)
                    .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .foregroundStyle(isOn ? .white : .secondary)
            .background(isOn ? Color.accentColor : Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ button: QuickButton) {
        var current = QuickButton.decode(enabledQuickButtonsRaw)
        if current.contains(button) {
            current.removeAll { $0 == button }
        } else {
            // Canonical order keeps the row stable regardless of toggle sequence.
            current = QuickButton.allCases.filter { current.contains($0) || $0 == button }
        }
        enabledQuickButtonsRaw = QuickButton.encode(current)
    }

}

/// State for the inline connection-test probe that sits next to the URL field.
/// Kept separate from `client.isConnected` so we can offer a "just reach out
/// and see" button that doesn't disturb an active session.
enum ConnectionTestState: Equatable {
    case idle
    case testing
    case success(String)
    case failed(String)

    var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    /// One-line status to show inline under the URL field. `nil` hides the pill.
    var resultMessage: String? {
        switch self {
        case .idle, .testing: return nil
        case .success(let msg), .failed(let msg): return msg
        }
    }
}

private enum ConnectionProbeError: Error {
    case timeout(TimeInterval)
}

/// Three-way zoom control for the terminal content screenshot. Shared by
/// portrait InlineTerminalContent and landscape TerminalContentOverlay so
/// cycling in one carries over to the other.
///
/// Percentage-based (of container width) rather than fixed point padding —
/// landscape is >2x as wide as portrait, so a fixed 24pt margin in portrait
/// is barely visible in landscape and text still renders huge.
enum ContentZoomLevel: Int, CaseIterable {
    case fill = 0, medium = 1, small = 2

    /// Fraction of the container width the image should fill. Remaining
    /// space becomes evenly-split horizontal margin.
    var widthFraction: CGFloat {
        switch self {
        case .fill: return 1.0
        case .medium: return 0.82
        case .small: return 0.62
        }
    }

    static func from(raw: Int) -> ContentZoomLevel {
        ContentZoomLevel(rawValue: raw) ?? .medium
    }

    var next: Int {
        (rawValue + 1) % ContentZoomLevel.allCases.count
    }
}
