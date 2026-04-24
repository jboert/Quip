import SwiftUI
import AVFoundation

// Controls orientation lock — portrait when disconnected, all orientations when connected.
// Also owns the APNs device-token callbacks — the callbacks must land on a
// UIApplicationDelegate, not on the SwiftUI App, so this is the right
// home for them even though the orientation logic is unrelated.
class AppOrientationDelegate: NSObject, UIApplicationDelegate {
    static var allowAllOrientations = false

    /// Bridge between UIKit's APNs callbacks and our @Observable
    /// PushRegistrationService. Set from QuipApp at construction time.
    static var pushRegistration: PushRegistrationService?

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.allowAllOrientations ? .allButUpsideDown : .portrait
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            Self.pushRegistration?.registerDeviceToken(deviceToken)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            Self.pushRegistration?.registrationFailed(error)
        }
    }
}

@main
struct QuipApp: App {
    @UIApplicationDelegateAdaptor(AppOrientationDelegate.self) var appDelegate
    @State private var client = WebSocketClient()
    @State private var speech = SpeechService()
    @State private var volumeHandler = HardwareButtonHandler()
    @State private var bonjourBrowser = BonjourBrowser()
    @State private var pushRegistration = PushRegistrationService()
    @State private var attentionCenter = WindowAttentionCenter()
    @State private var pushDelegate = PushNotificationCenterDelegate()
    @State private var liveActivity = LiveActivityService()
    @State private var prefsSync = PreferencesSyncService()

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
    /// URLs extracted Mac-side from the scraped text, for the tap-to-open
    /// tray. nil until first content arrives; empty array from an older Mac
    /// build (pre-tray) reads as "no URLs" and hides the tray.
    @State private var terminalContentURLs: [String]?
    @State private var terminalContentWindowId: String?
    @State private var showPINEntry = false
    @State private var pinText = ""
    @State private var projectDirectories: [String] = []
    /// nil = scan hasn't been requested yet or is in-flight; [] = scanned,
    /// no windows; populated = scanned successfully. Lives on QuipApp (not
    /// MainiOSView) because the Mac's `iterm_window_list` response is
    /// decoded in QuipApp's `onITermWindowList` callback. Passed down as
    /// a Binding so the sheet can clear it before re-scanning.
    @State private var iTermScanResults: [ITermWindowInfo]? = nil
    /// Most recent Mac TCC permission snapshot. nil = Mac hasn't sent one yet
    /// (older Mac build, or just connected and waiting for the first probe).
    @State private var macPermissions: MacPermissionsMessage? = nil
    @State private var errorToast: String?
    @AppStorage("ttsEnabled") private var ttsEnabled = false
    /// Master toggle for the Dynamic Island / Lock Screen Live Activity.
    /// Default on — if the user's already wired up push they almost
    /// certainly want the island card too. Flipping it off tears down
    /// any in-flight activity (see `.onChange` below).
    @AppStorage("liveActivitiesEnabled") private var liveActivitiesEnabled = true
    /// Quiet-hours window for Live Activities. Live Activities bypass the
    /// Mac's APNs prefs (WebSocket-driven, not APNs), so the quiet-hours
    /// check is duplicated here instead of relying on the Mac-side gate.
    /// Start/end are 0-23 hours in the phone's local TZ.
    @AppStorage("pushQuietHoursEnabled") private var quietHoursEnabled = false
    @AppStorage("pushQuietHoursStart") private var quietHoursStart = 22
    @AppStorage("pushQuietHoursEnd") private var quietHoursEnd = 7
    /// Output delta text per window — used to display TTS overlay captions
    @State private var ttsOverlayTexts: [String: String] = [:]
    /// Pending image attachment — hoisted to QuipApp (from MainiOSView) so
    /// PTT stopRecording can flush a queued image even though that closure
    /// lives at the App level. Propagated to MainiOSView and
    /// TerminalContentOverlay via .environmentObject.
    @StateObject private var pendingImage = PendingImageState()
    private let imageRecompressor = ImageRecompressor(maxPayloadBytes: 7_300_000)

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
                terminalContentURLs: $terminalContentURLs,
                terminalContentWindowId: $terminalContentWindowId,
                showPINEntry: $showPINEntry,
                pinText: $pinText,
                projectDirectories: projectDirectories,
                iTermScanResults: $iTermScanResults,
                pushRegistration: pushRegistration,
                attentionCenter: attentionCenter,
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
                },
                macPermissions: macPermissions
            )
            .environmentObject(pendingImage)
            .onAppear {
                setup()
                bonjourBrowser.startBrowsing()
                // Bridge APNs callbacks from UIKit-land to our @Observable
                // service. Done in onAppear (not init) because @State values
                // aren't available during the struct initializer.
                AppOrientationDelegate.pushRegistration = pushRegistration

                // Wire the UNUserNotificationCenter delegate + its hooks.
                // The delegate itself is set once here; its closures read
                // live @State via captures, which is fine since they're
                // invoked on the main actor.
                UNUserNotificationCenter.current().delegate = pushDelegate
                pushDelegate.onWaitingForInput = { windowId in
                    attentionCenter.markNeedsAttention(windowId)
                }
                pushDelegate.onNotificationTap = { windowId in
                    selectedWindowId = windowId
                    attentionCenter.clearAttention(for: windowId)
                    // Surface the text input so the user can type immediately.
                    showTextInput = true
                    // Tell the Mac too — keeps their selection state in sync
                    // so subsequent waiting_for_input on other windows doesn't
                    // steal focus.
                    client.send(SelectWindowMessage(windowId: windowId))
                }
                pushDelegate.currentlySelectedWindowId = { selectedWindowId }
                pushDelegate.foregroundBannerEnabled = {
                    UserDefaults.standard.bool(forKey: "pushForegroundBanner")
                }
            }
            .onChange(of: selectedWindowId) { _, newId in
                // User engaged with a window — clear its attention flag so
                // the pulsing dot and badge count go quiet. Fires from every
                // selection path: tap, Mac echo, deep-link tap, etc.
                if let newId { attentionCenter.clearAttention(for: newId) }
            }
            .onChange(of: liveActivitiesEnabled) { _, enabled in
                // Flipping Live Activities off in Settings should drop any
                // in-flight island card immediately. Without this, the toggle
                // would stop NEW activities from starting but whatever's
                // already on screen (thinking/waiting) would linger until
                // the Mac sent another state change — so the setting looks
                // like it didn't take.
                if !enabled { liveActivity.endAll() }
            }
            .onOpenURL { url in
                // Deep link from the Live Activity island / lock screen:
                //   quip://window/<windowId> — select that window + open input
                //   quip://perms            — pop the SettingsSheet open (Mac
                //                             perms section is at the top)
                guard url.scheme == "quip" else { return }
                if url.host == "perms" {
                    NotificationCenter.default.post(name: .quipShowSettings, object: nil)
                    return
                }
                let windowId: String
                if url.host == "window" {
                    windowId = url.pathComponents.dropFirst().first ?? ""
                } else if let host = url.host, !host.isEmpty, url.pathComponents.count <= 1 {
                    // Fallback: quip://<windowId> (no "window/" prefix)
                    windowId = host
                } else {
                    return
                }
                guard !windowId.isEmpty else { return }
                selectedWindowId = windowId
                attentionCenter.clearAttention(for: windowId)
                showTextInput = true
                client.send(SelectWindowMessage(windowId: windowId))
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
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                volumeHandler.stopMonitoring()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                // Probe the socket on return; force-reconnect with reset backoff
                // if the probe doesn't pong within 2s.
                client.resumeFromBackground()
            }
        }
    }

    /// True when the current wall-clock hour falls inside the user's
    /// quiet-hours window. Handles both same-day (9-17) and overnight
    /// (22-7) ranges. Mirrors the Mac-side `DevicePushPreferences.isQuietNow`
    /// so both the APNs path and the Live Activity path agree.
    private func isInQuietHoursNow(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled else { return false }
        let hour = calendar.component(.hour, from: now)
        if quietHoursStart == quietHoursEnd { return false }
        if quietHoursStart < quietHoursEnd {
            return hour >= quietHoursStart && hour < quietHoursEnd
        }
        return hour >= quietHoursStart || hour < quietHoursEnd
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

        client.onITermWindowList = { infos in
            DispatchQueue.main.async {
                iTermScanResults = infos
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
                    // Drive the Dynamic Island Live Activity for the user's
                    // currently-selected window. PRD scope: only the selected
                    // window gets an island; every other thinking window is
                    // tracked by the Mac but doesn't pop its own activity.
                    if windowId == selectedWindowId, liveActivitiesEnabled {
                        // During quiet hours, suppress start/update so no new
                        // island card pops and existing cards stop changing
                        // state. `end` still fires on neutral so anything that
                        // started before quiet hours can clean itself up.
                        let islandState: String? = switch newState {
                        case "thinking": "thinking"
                        case "waiting_for_input": "waiting"
                        default: nil
                        }
                        if let islandState, !isInQuietHoursNow() {
                            liveActivity.startOrUpdate(windowId: windowId, windowName: w.name, state: islandState)
                        } else if islandState == nil {
                            // neutral or anything else: user is actively engaged
                            // with the terminal; no need for an island card.
                            liveActivity.end(windowId: windowId)
                        }
                    }
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

        client.onTerminalContent = { windowId, content, screenshot, urls in
            DispatchQueue.main.async {
                terminalContentWindowId = windowId
                terminalContentText = content
                // Preserve last-good screenshot when the new update doesn't
                // carry one — happens on Mac Screen Recording revocation
                // (cdhash change after a Mac rebuild), Tailscale reconnects,
                // network switches, or momentary Mac CPU spikes where
                // screencapture returns nil. Without this, the iOS panel
                // would drop to "Loading…" on every bad refresh even though
                // the window state hasn't actually changed. Window switches
                // still clear via `selectedWindowId.onChange` so we never
                // show stale content from the wrong window.
                if let screenshot, !screenshot.isEmpty {
                    terminalContentScreenshot = screenshot
                }
                terminalContentURLs = urls
            }
        }

        client.onMacPermissions = { snapshot in
            DispatchQueue.main.async {
                macPermissions = snapshot
                let denied = snapshot.deniedCount
                if liveActivitiesEnabled {
                    if denied > 0 {
                        liveActivity.startOrUpdateMacPerms(deniedCount: denied)
                    } else {
                        liveActivity.endMacPerms()
                    }
                }
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
                    // Prompt for notification permission (if needed) and hand
                    // the Mac our device token. Fine to call on every auth
                    // success — prompt only shows the first time, and token
                    // re-send is idempotent on the Mac side.
                    Task { @MainActor in
                        await pushRegistration.requestPermissionAndRegister()
                        if let token = pushRegistration.deviceToken {
                            client.send(RegisterPushDeviceMessage(
                                deviceToken: token,
                                environment: pushRegistration.environment
                            ))
                            // Also sync prefs so the Mac honors Pause etc. right
                            // away — avoids a window where the Mac pushes with
                            // stale defaults before the user opens Settings.
                            let ud = UserDefaults.standard
                            let qhEnabled = ud.bool(forKey: "pushQuietHoursEnabled")
                            let prefs = PushPreferencesMessage(
                                deviceToken: token,
                                paused: ud.bool(forKey: "pushPaused"),
                                quietHoursStart: qhEnabled ? (ud.object(forKey: "pushQuietHoursStart") as? Int ?? 22) : nil,
                                quietHoursEnd: qhEnabled ? (ud.object(forKey: "pushQuietHoursEnd") as? Int ?? 7) : nil,
                                sound: ud.object(forKey: "pushSound") as? Bool ?? true,
                                foregroundBanner: ud.bool(forKey: "pushForegroundBanner"),
                                bannerEnabled: ud.object(forKey: "pushBannerEnabled") as? Bool ?? true,
                                timeZone: TimeZone.current.identifier
                            )
                            client.send(prefs)
                        }
                    }
                    // Ask the Mac for our backed-up preferences. If this is a
                    // fresh reinstall, the Mac will push back whatever we last
                    // synced; otherwise it'll send an empty snapshot and the
                    // local UserDefaults stay as-is.
                    prefsSync.requestRestore()
                }
                // On failure, PIN entry stays open — authError displayed in the UI
            }
        }

        client.onPreferencesRestore = { snapshot in
            DispatchQueue.main.async {
                prefsSync.applyRestore(snapshot)
            }
        }

        // Wire the sync service to actually transmit via the WebSocket. Done
        // once at setup so every UserDefaults change can fire-and-forget.
        prefsSync.send = { [client] data in
            client.sendRaw(data)
        }
        prefsSync.start()

        volumeHandler.onPTTStart = {
            DispatchQueue.main.async { startRecording() }
        }

        volumeHandler.onPTTStop = {
            DispatchQueue.main.async { stopRecording() }
        }

        volumeHandler.onArm = { speech.arm() }
        volumeHandler.onDisarm = { speech.disarm() }
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
            // Flush a queued image first — defer the STT-ended + dictated text
            // until after the image actually hits the wire so the Mac processes
            // them in order (path first, then dictated text).
            flushPendingImage(windowId: windowId) { [client] in
                client.send(STTStateMessage.ended(windowId: windowId))
                if !text.isEmpty {
                    client.send(SendTextMessage(windowId: windowId, text: text, pressReturn: false))
                }
            }
        }
    }

    /// Ship the queued image (if any) to the Mac for the given window. Shared
    /// logic used by PTT stopRecording here and by MainiOSView's submit paths.
    /// `afterSend` runs on the main thread AFTER the WebSocket send has been
    /// issued — callers use it to fire follow-up messages (like press_return)
    /// so they don't race ahead of the image over the wire.
    @MainActor
    fileprivate func flushPendingImage(windowId: String, afterSend: (@MainActor () -> Void)? = nil) {
        guard let image = pendingImage.image,
              let filename = pendingImage.filename,
              let mime = pendingImage.mimeType else {
            afterSend?()
            return
        }
        pendingImage.markUploading()
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
                    afterSend?()
                }
                return
            }
            do {
                let (data, finalMime) = try recompressor.recompress(rawData: rawData, declaredMime: mime)
                let base64 = data.base64EncodedString()
                NSLog("[Quip] flushPendingImage: sending image_upload msg, payload=%d bytes", base64.count)
                let msg = ImageUploadMessage(
                    imageId: UUID().uuidString,
                    windowId: windowId,
                    filename: filename,
                    mimeType: finalMime,
                    data: base64
                )
                DispatchQueue.main.async {
                    clientRef.send(msg)
                    afterSend?()
                }
            } catch {
                DispatchQueue.main.async { [weak pendingImage] in
                    pendingImage?.markError("image too large to send")
                    afterSend?()
                }
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
    @Binding var terminalContentURLs: [String]?
    @Binding var terminalContentWindowId: String?
    @Binding var showPINEntry: Bool
    @Binding var pinText: String
    var projectDirectories: [String]
    @Binding var iTermScanResults: [ITermWindowInfo]?
    var pushRegistration: PushRegistrationService
    var attentionCenter: WindowAttentionCenter
    @Binding var errorToast: String?
    var ttsOverlayTexts: [String: String]
    var monitorName: String
    var screenAspect: Double
    @Binding var showTextInput: Bool
    @Binding var textInputValue: String
    var onStartRecording: () -> Void
    var onStopRecording: () -> Void
    var onRequestContent: (String) -> Void
    var macPermissions: MacPermissionsMessage?
    /// Tracks whether we've already auto-popped the SettingsSheet for the
    /// current connection's first degraded snapshot. Reset on disconnect so a
    /// reconnect can re-pop if Mac is still degraded — but the 5s update
    /// stream doesn't keep re-popping after the user dismisses.
    @State private var hasAutoShownPermsForConnection = false

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
    /// Which tab the Spawn sheet is on. "new" shows project directories
    /// (classic path), "attach" shows the list of iTerm windows currently
    /// open on the Mac that Quip isn't already tracking.
    @State private var spawnSheetTab: SpawnSheetTab = .new
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
    @AppStorage("terminalHeightFraction") private var terminalHeightFraction: Double = 0.72
    @GestureState private var dragFractionDelta: Double = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var colors: QuipColors { QuipColors(scheme: colorScheme) }
    private var isPortrait: Bool { verticalSizeClass == .regular }

    // Pending image attachment — shared between portrait and landscape input rows.
    // Owned by QuipApp and injected via environmentObject so PTT stopRecording
    // (which lives at the App level) can reach the same instance.
    @EnvironmentObject private var pendingImage: PendingImageState
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
                    landscapeContentSection
                    if showTextInput {
                        textInputBar
                    }
                }

                if client.isAuthenticated && !windows.isEmpty {
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
                DispatchQueue.main.async {
                    // Brief checkmark flash over the thumbnail so the user
                    // sees the path actually landed in the prompt before
                    // the preview strip vanishes.
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)
                    pendingImage?.markSentAndClear()
                }
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
                    // Reset auto-pop guard so the next reconnect can re-pop
                    // the SettingsSheet if Mac is still degraded.
                    hasAutoShownPermsForConnection = false
                    // If an upload was in flight when the socket dropped,
                    // the ack will never come back. Flip the thumbnail to
                    // an error state immediately so the user can dismiss
                    // it — otherwise they stare at a spinner for 10s
                    // (the watchdog) or longer, with no visible way out
                    // until the watchdog trips.
                    if pendingImage.uploadState == .uploading {
                        pendingImage.markError("disconnected — try again")
                    }
                }
                updateOrientation()
            }
        }
        .onChange(of: macPermissions) { _, snapshot in
            // First snapshot of a connection: if Mac is degraded, auto-pop
            // the SettingsSheet so the user lands on the perm strip without
            // a manual nav. Only fires once per connection — the 5s update
            // stream wouldn't get past the guard, and dismissing won't re-pop.
            guard let s = snapshot, s.deniedCount > 0, !hasAutoShownPermsForConnection else { return }
            hasAutoShownPermsForConnection = true
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .quipShowSettings)) { _ in
            // Triggered by the `quip://perms` deep link from the Mac-perms
            // Live Activity. Goes straight to the SettingsSheet (Mac
            // Permissions section is at the top).
            showSettings = true
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
            terminalContentURLs = nil
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
            SettingsSheet(
                enabledQuickButtonsRaw: $enabledQuickButtonsRaw,
                client: client,
                pushRegistration: pushRegistration,
                macPermissions: macPermissions
            )
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
                VStack(spacing: 0) {
                    Picker("", selection: $spawnSheetTab) {
                        ForEach(SpawnSheetTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)

                    Group {
                        if spawnSheetTab == .new {
                            spawnSheetNewTab
                        } else {
                            spawnSheetAttachTab
                        }
                    }
                }
                .navigationTitle(spawnSheetTab == .new ? "New Window" : "Attach Existing")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showSpawnPicker = false }
                    }
                    if spawnSheetTab == .attach {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                requestITermScan()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .accessibilityLabel("Rescan")
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .onChange(of: spawnSheetTab) { _, newValue in
                if newValue == .attach { requestITermScan() }
            }
            .onChange(of: showSpawnPicker) { _, isShowing in
                // Reset tab + scan state whenever the sheet closes so the
                // next open starts from a clean slate.
                if !isShowing {
                    spawnSheetTab = .new
                    iTermScanResults = nil
                }
            }
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

    // MARK: - Spawn Sheet Tabs

    @ViewBuilder
    private var spawnSheetNewTab: some View {
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
    }

    @ViewBuilder
    private var spawnSheetAttachTab: some View {
        Group {
            if let results = iTermScanResults {
                if results.isEmpty {
                    ContentUnavailableView(
                        "No iTerm Windows",
                        systemImage: "terminal",
                        description: Text("Open an iTerm window on the Mac, then tap the refresh button above.")
                    )
                } else {
                    List {
                        ForEach(results, id: \.sessionId) { info in
                            iTermWindowRow(info: info)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { requestITermScan() }
                }
            } else {
                // nil = in-flight scan. Show a spinner instead of empty state.
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Scanning iTerm windows…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func iTermWindowRow(info: ITermWindowInfo) -> some View {
        let dimmed = info.isAlreadyTracked || info.isMiniaturized
        Button {
            guard !info.isAlreadyTracked else { return }
            client.send(AttachITermWindowMessage(
                windowNumber: info.windowNumber,
                sessionId: info.sessionId
            ))
            showSpawnPicker = false
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(info.isAlreadyTracked ? Color.secondary : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title.isEmpty ? "(untitled)" : info.title)
                        .font(.body)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(cwdShortLabel(info.cwd))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if info.isMiniaturized {
                            Text("minimized")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 8)
                if info.isAlreadyTracked {
                    Text("Attached")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            .contentShape(Rectangle())
            .opacity(dimmed && !info.isAlreadyTracked ? 0.6 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(info.isAlreadyTracked)
    }

    /// Trim the cwd to the last two path components so the row doesn't wrap
    /// on long absolute paths (`/Users/dev/Projects/Foo/src` → `Foo/src`).
    private func cwdShortLabel(_ cwd: String) -> String {
        guard !cwd.isEmpty else { return "(no cwd)" }
        let comps = (cwd as NSString).pathComponents.filter { $0 != "/" }
        if comps.count >= 2 { return comps.suffix(2).joined(separator: "/") }
        return (cwd as NSString).lastPathComponent
    }

    /// Clear any prior results and ask the Mac for a fresh list. The
    /// response arrives asynchronously via `onITermWindowList` → the View
    /// re-renders with the list.
    private func requestITermScan() {
        iTermScanResults = nil
        client.send(ScanITermWindowsMessage())
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
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textTertiary)
                        .frame(width: 20, height: 20)
                    // Red dot when any Mac TCC perm is denied so the user
                    // notices something needs attention without having to
                    // open the sheet to find out.
                    if let perms = macPermissions,
                       !(perms.accessibility && perms.appleEvents && perms.screenRecording) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
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
        // Landscape is short on vertical space — tighten the button sizes so
        // the full row of controls + quick-button row fits without crowding.
        let btnH: CGFloat = isPortrait ? 56 : 40
        let btnW: CGFloat = isPortrait ? 56 : 44
        let pttW: CGFloat = isPortrait ? 72 : 56
        let navW: CGFloat = isPortrait ? 26 : 22
        let navH: CGFloat = isPortrait ? 36 : 28
        let auxW: CGFloat = isPortrait ? 40 : 32
        let auxH: CGFloat = isPortrait ? 56 : 40

        return VStack(spacing: isPortrait ? 8 : 4) {
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
                        .frame(width: navW, height: navH)
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
                        .frame(width: navW, height: navH)
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
                        .frame(width: auxW, height: auxH)
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
                        .frame(width: auxW, height: auxH)
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
                        .frame(width: pttW, height: btnH)
                        .background(colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.red.opacity(0.7), lineWidth: isRecording ? 2 : 0)
                        )
                }
                Spacer()

                // Attach image — sits adjacent to the PTT mic since both are
                // primary input actions (drop in media vs. speak). Tapping
                // opens source picker (library / camera).
                Button {
                    showingImageSourceSheet = true
                } label: {
                    Image(systemName: pendingImage.hasPendingImage ? "photo.fill" : "photo")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(pendingImage.hasPendingImage ? colors.buttonPrimary : colors.textPrimary)
                        .frame(width: btnW, height: btnH)
                        .background(colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("Attach image")

                // Type — toggles the text input bar above the terminal
                // content. Sized down to the secondary tier (matches `+`
                // and Arrange) since it's a mode toggle, not a send action.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showTextInput.toggle()
                        if !showTextInput { textInputValue = "" }
                    }
                } label: {
                    Image(systemName: showTextInput ? "keyboard.chevron.compact.down" : "keyboard")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(colors.textPrimary)
                        .frame(width: auxW, height: auxH)
                        .background(colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // Press Return — flushes any pending image first AND defers the
                // press_return until the image has actually been dispatched, so
                // the Mac receives them in the correct order (path first, then
                // Enter) rather than racing and pressing Enter before the path
                // types.
                Button {
                    if let wid = selectedWindowId {
                        sendPendingImageIfNeeded(windowId: wid) {
                            client.send(QuickActionMessage(windowId: wid, action: "press_return"))
                        }
                    }
                } label: {
                    Image(systemName: "return")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(selectedWindowId != nil ? colors.textPrimary : colors.textFaint)
                        .frame(width: btnW, height: btnH)
                        .background(colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(selectedWindowId == nil)

                // In landscape, fold the quick-button row INTO this main row
                // — saves a whole row of vertical space and keeps everything
                // reachable in one thumb-sweep. Portrait keeps the 2-row
                // layout below because there isn't width to spare.
                if !isPortrait {
                    let enabled = QuickButton.decode(enabledQuickButtonsRaw)
                    if !enabled.isEmpty {
                        Spacer().frame(width: 8)
                        ForEach(Array(enabled.enumerated()), id: \.element.id) { index, button in
                            if index > 0, enabled[index - 1].isSlashCommand != button.isSlashCommand {
                                Spacer().frame(width: 6)
                            }
                            quickActionButton(button)
                        }
                    }
                }
            }

            // Portrait-only secondary command-shortcut row. Buttons are
            // grouped left/center/right by category so the center group
            // (answers — Y/N/1/2/3) lines up vertically with the mic
            // above, which is also Spacer-pinned to the row's center.
            if isPortrait {
                let enabled = QuickButton.decode(enabledQuickButtonsRaw)
                if !enabled.isEmpty {
                    let slash = enabled.filter { $0.category == .slash }
                    let yesNo = enabled.filter { $0 == .yes || $0 == .no }
                    let numbers = enabled.filter { $0 == .one || $0 == .two || $0 == .three }
                    let keystroke = enabled.filter { $0.category == .keystroke }
                    HStack(spacing: 3) {
                        ForEach(slash) { quickActionButton($0) }
                        Spacer(minLength: 6)
                        ForEach(yesNo) { quickActionButton($0) }
                        // Small fixed gap between Y/N (confirmations) and
                        // 1/2/3 (numbered choices) — both are "answers" but
                        // visually distinct sub-groups.
                        if !yesNo.isEmpty, !numbers.isEmpty {
                            Spacer().frame(width: 8)
                        }
                        ForEach(numbers) { quickActionButton($0) }
                        Spacer(minLength: 6)
                        ForEach(keystroke) { quickActionButton($0) }
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
        .padding(.vertical, isPortrait ? 8 : 4)
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
            if let rawVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
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
        textInputValue = ""
        // Ship the image first; only fire the text send AFTER the image has
        // actually been dispatched so the Mac processes them in order.
        sendPendingImageIfNeeded(windowId: windowId) { [client] in
            if !text.isEmpty {
                client.send(SendTextMessage(windowId: windowId, text: text, pressReturn: true))
            }
        }
    }

    // MARK: - Image Upload

    private let imageRecompressor = ImageRecompressor(maxPayloadBytes: 7_300_000)

    /// `afterSend` runs on the main thread AFTER the WebSocket send has been
    /// issued — callers use it to fire follow-up messages (like press_return)
    /// so they don't race ahead of the image over the wire. When no image is
    /// queued, the callback fires immediately so the normal submit path still
    /// runs.
    @MainActor
    private func sendPendingImageIfNeeded(windowId: String, afterSend: (@MainActor () -> Void)? = nil) {
        NSLog("[Quip-iOS] sendPendingImageIfNeeded called for windowId=%@, hasImage=%@", windowId, pendingImage.image == nil ? "NO" : "YES")
        guard let image = pendingImage.image,
              let filename = pendingImage.filename,
              let mime = pendingImage.mimeType else {
            afterSend?()
            return
        }

        pendingImage.markUploading()

        // Capture value types so the closure doesn't hold a reference to self.
        let recompressor = imageRecompressor
        let clientRef = client

        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.main.async { [weak pendingImage] in pendingImage?.setDebugStage("encoding-start") }
            let rawData: Data?
            if mime == "image/png" {
                rawData = image.pngData()
            } else {
                rawData = image.jpegData(compressionQuality: 0.95)
            }
            guard let rawData else {
                DispatchQueue.main.async { [weak pendingImage] in
                    pendingImage?.markError("couldn't encode image")
                    afterSend?()
                }
                return
            }
            DispatchQueue.main.async { [weak pendingImage, c = rawData.count] in pendingImage?.setDebugStage("encoded \(c)B") }
            do {
                let (data, finalMime) = try recompressor.recompress(rawData: rawData, declaredMime: mime)
                let base64 = data.base64EncodedString()
                NSLog("[Quip-iOS] sendPendingImageIfNeeded: dispatching image_upload, base64=%d bytes", base64.count)
                let msg = ImageUploadMessage(
                    imageId: UUID().uuidString,
                    windowId: windowId,
                    filename: filename,
                    mimeType: finalMime,
                    data: base64
                )
                DispatchQueue.main.async { [weak pendingImage, n = base64.count] in
                    pendingImage?.setDebugStage("sending b64=\(n)B")
                    clientRef.send(msg)
                    pendingImage?.setDebugStage("sent, awaiting ack")
                    afterSend?()
                }
            } catch {
                DispatchQueue.main.async { [weak pendingImage] in
                    pendingImage?.markError("image too large to send")
                    afterSend?()
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

    // Landscape horizontal split — window picker on the left, terminal on the
    // right, draggable divider in between. Separate @AppStorage key so the
    // ratio you pick in landscape doesn't mess with the portrait ratio.
    @AppStorage("terminalWidthFraction") private var terminalWidthFraction: Double = 0.7
    @GestureState private var dragWidthFractionDelta: Double = 0
    private var resolvedTerminalWidthFraction: Double {
        min(0.9, max(0.1, terminalWidthFraction - dragWidthFractionDelta))
    }

    @ViewBuilder
    private var landscapeContentSection: some View {
        let hasTerminal = client.isAuthenticated && selectedWindowId != nil
        if hasTerminal {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    if !isTerminalExpanded {
                        windowLayout
                            .frame(width: geo.size.width * (1 - resolvedTerminalWidthFraction))
                            .padding(.vertical, 4)
                            .padding(.leading, 4)
                        resizeHandleVertical(containerWidth: geo.size.width)
                    }
                    terminalContentView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Same horizontal breathing room as portrait so the
                        // tinted window-color border is visible on ALL four
                        // sides. Landscape was missing the leading inset
                        // (only had trailing 8), which let the terminal card
                        // run flush against the drag handle / left bezel.
                        .padding(.vertical, 6)
                        .padding(.leading, 8)
                        .padding(.trailing, 12)
                }
            }
        } else {
            windowLayout
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            Spacer(minLength: 0)
        }
    }

    /// Vertical drag handle between windowLayout (left) and terminalContentView
    /// (right) in landscape. Mirrors `resizeHandle` but along the x-axis. Drag
    /// right → windowLayout grows, terminal shrinks.
    private func resizeHandleVertical(containerWidth: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 0.5)
                .frame(maxHeight: .infinity)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.5))
                .frame(width: 4, height: 44)
        }
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .updating($dragWidthFractionDelta) { value, state, _ in
                    state = containerWidth > 0 ? Double(value.translation.width) / Double(containerWidth) : 0
                }
                .onEnded { value in
                    guard containerWidth > 0 else { return }
                    let delta = Double(value.translation.width) / Double(containerWidth)
                    terminalWidthFraction = min(0.9, max(0.1, terminalWidthFraction - delta))
                }
        )
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
                        // Horizontal inset so the tinted window-color border
                        // on left/right is visible instead of being clipped
                        // by the display's rounded corners.
                        .padding(.horizontal, 12)
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
            urls: terminalContentURLs ?? [],
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
            },
            onCycleWindow: { direction in cycleWindow(direction: direction) }
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
                            // Pulsing yellow dot overlay when this window's
                            // waiting for user input. Drawn in the top-right
                            // of the rect so it doesn't cover the window
                            // name or color-dot. zIndex bump pulls the whole
                            // card on top of overlapping neighbors — the
                            // "auto front-load" behavior from the PRD.
                            .overlay(alignment: .topTrailing) {
                                if attentionCenter.windowsNeedingAttention.contains(window.id) {
                                    AttentionPulseDot()
                                        .frame(width: 12, height: 12)
                                        .offset(x: -4, y: 4)
                                }
                            }
                            .zIndex(attentionCenter.windowsNeedingAttention.contains(window.id) ? 10 : 0)
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
                // Auto-submitting text is a "submit" — flush any pending image
                // first and defer the text send until after the image hits the
                // wire so the Mac processes them in order.
                if pressReturn {
                    sendPendingImageIfNeeded(windowId: wid) { [client] in
                        client.send(SendTextMessage(windowId: wid, text: text, pressReturn: pressReturn))
                    }
                } else {
                    client.send(SendTextMessage(windowId: wid, text: text, pressReturn: pressReturn))
                }
            case .quickAction(let action):
                if action == "press_return" {
                    sendPendingImageIfNeeded(windowId: wid) { [client] in
                        client.send(QuickActionMessage(windowId: wid, action: action))
                    }
                } else {
                    client.send(QuickActionMessage(windowId: wid, action: action))
                }
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
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .frame(minWidth: 20)
            .background(Color.white.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 5))
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

/// Small yellow dot that pulses to draw attention to a window card.
/// Used on the window picker when Claude is waiting for input — subtle
/// foreground-state signal since the PRD calls for no banner here.
struct AttentionPulseDot: View {
    @State private var scale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.yellow.opacity(0.5))
                .scaleEffect(scale)
            Circle()
                .fill(Color.yellow)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                scale = 1.8
            }
        }
    }
}

/// `UITextView`-backed terminal text view. SwiftUI `Text` with `.link`
/// AttributedString is documented to be tappable but in practice tap routing
/// drops to the floor inside our InlineTerminalContent layout (parent
/// ScrollView gestures + view-modifier cascades both interfere). UITextView
/// owns its own gesture stack and tap-to-open-url is rock solid.
///
/// The view uses `dataDetectorTypes = .link` plus `linkTextAttributes` for
/// styling, and gets the SAME scheme filter as `linkifiedTerminalContent` via
/// a delegate `shouldInteractWith url:` hook that rejects taps on non-http(s)
/// matches (so README.md / Quip.app render as links visually but ignore the
/// tap; that's a minor cosmetic loss vs. the alternative of building the
/// attributed string by hand).
struct LinkableTerminalText: UIViewRepresentable {
    let content: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = true            // owns scrolling
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        tv.textContainer.lineFragmentPadding = 0
        tv.dataDetectorTypes = .link
        tv.linkTextAttributes = [
            .foregroundColor: UIColor.cyan,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        tv.delegate = context.coordinator
        tv.alwaysBounceVertical = true
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let attr = NSMutableAttributedString(string: content, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: UIColor.white.withAlphaComponent(0.85),
        ])
        tv.attributedText = attr
        // Auto-scroll to bottom on new content so latest output is visible
        // (mirrors the SwiftUI ScrollViewReader.scrollTo("bottom") pattern).
        let bottom = NSRange(location: max(0, attr.length - 1), length: 1)
        tv.scrollRangeToVisible(bottom)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        /// iOS 17+ tap handler. The OLD `shouldInteractWith url:in:interaction:`
        /// delegate method is deprecated; iOS 17 routes taps through this method
        /// instead and falls through to a no-op if it returns nil. Returning
        /// the system's default openURL action — wrapped in a fresh UIAction
        /// to FORCE immediate execution rather than the iOS 17 default of
        /// showing a Safari-style preview menu first.
        ///
        /// Scheme filter: `dataDetectorTypes = .link` matches bare TLDs
        /// (`README.md` → `http://README.md`, `Quip.app` → `http://Quip.app`).
        /// We reject those by inspecting the original substring's prefix.
        @available(iOS 17.0, *)
        func textView(_ textView: UITextView,
                      primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            let scheme = url.scheme?.lowercased() ?? ""
            let allowed: Bool
            if scheme == "mailto" {
                allowed = true
            } else if scheme == "http" || scheme == "https" {
                let raw = (textView.attributedText.string as NSString).substring(with: textItem.range)
                allowed = raw.hasPrefix("http://") || raw.hasPrefix("https://")
            } else {
                allowed = false
            }
            guard allowed else { return nil }
            // Return a custom UIAction that calls UIApplication.shared.open
            // directly. iOS 17's defaultAction sometimes resolves to "show
            // preview popover" instead of "open immediately"; this guarantees
            // immediate openURL on tap.
            return UIAction(title: "Open Link") { _ in
                UIApplication.shared.open(url, options: [:]) { success in
                    if !success {
                        NSLog("[LinkableTerminalText] open(%@) returned false", url.absoluteString)
                    }
                }
            }
        }

        /// Suppress the iOS 17 link preview menu so tap → open immediately
        /// without an intermediate "show URL preview" popover.
        @available(iOS 17.0, *)
        func textView(_ textView: UITextView,
                      menuConfigurationFor textItem: UITextItem,
                      defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            return nil
        }

        /// Pre-iOS 17 fallback (unreachable on this app — deployment target is
        /// iOS 17.0 — but kept defensively in case the project bumps backward).
        func textView(_ textView: UITextView, shouldInteractWith URL: URL,
                      in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            let scheme = URL.scheme?.lowercased() ?? ""
            if scheme == "mailto" { return true }
            if scheme == "http" || scheme == "https" {
                let raw = (textView.attributedText.string as NSString).substring(with: characterRange)
                return raw.hasPrefix("http://") || raw.hasPrefix("https://")
            }
            return false
        }
    }
}

/// Wrap http(s) URLs in the terminal content with `.link` attributes so SwiftUI's
/// `Text` renders them as tappable. Only matches with an explicit `http://` or
/// `https://` prefix are linkified — `NSDataDetector` happily matches bare TLDs,
/// which would turn `README.md` (`.md` is a real TLD) and `Quip.app` into links.
///
/// Kept around for unit-test reuse + as documentation of the scheme-filter rule;
/// the actual render path now goes through `LinkableTerminalText` (UITextView).
func linkifiedTerminalContent(_ raw: String) -> AttributedString {
    var attr = AttributedString(raw)

    // Bake the default white foreground into the attributed string itself so
    // the call site doesn't need a `.foregroundStyle` modifier on the Text.
    // The modifier interferes with link-tap recognition by making SwiftUI
    // recompute foreground per-character at render time and stomping on the
    // link attribute's tap-routing. Setting it on the attributed string
    // leaves the per-run link runs intact and tappable.
    attr.foregroundColor = .white.opacity(0.85)

    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
        return attr
    }
    let ns = raw as NSString
    detector.enumerateMatches(in: raw, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
        guard let match, let url = match.url,
              let range = Range(match.range, in: attr) else { return }
        let matched = ns.substring(with: match.range)
        // Allow http(s) explicitly + mailto: for emails (NSDataDetector returns
        // bare addresses as `mailto:foo@bar.com` URLs natively, so this filter
        // accepts both `mailto:hi@example.com` substring matches and bare
        // `noreply@anthropic.com` matches surfaced by the detector).
        guard matched.hasPrefix("http://") || matched.hasPrefix("https://")
              || matched.hasPrefix("mailto:") || url.scheme?.lowercased() == "mailto"
        else { return }
        attr[range].link = url
        attr[range].underlineStyle = .single
        // Brighter foreground for link runs so they stand out from the .85
        // white body text — visually distinguishes "this is tappable".
        attr[range].foregroundColor = .cyan
    }
    return attr
}

struct InlineTerminalContent: View {
    let content: String
    let screenshot: String?
    /// URLs extracted Mac-side for the tap-to-open tray. Empty → tray hides.
    /// Screenshot mode (the typical case) renders URLs as pixels with no tap
    /// routing, so this tray is how they become interactive.
    let urls: [String]
    let windowName: String
    let windowColor: Color
    @Binding var isExpanded: Bool
    var onRefresh: () -> Void
    var onSendAction: (String) -> Void
    /// Swipe handler — `direction` is +1 (swipe left = next window) or -1
    /// (swipe right = previous window), matching `MainiOSView.cycleWindow`.
    /// Optional for previews / non-swiping callers.
    var onCycleWindow: ((Int) -> Void)? = nil
    @Environment(\.quipColors) private var colors
    @AppStorage("tintContentBorder") private var tintContentBorder = true
    /// Toggle for the tap-to-open URL tray. Default on. Users who don't want
    /// the extra row between header and screenshot can hide it from Settings.
    @AppStorage("urlTrayEnabled") private var urlTrayEnabled = true
    /// How many of the most recent URLs to show. Mac sends everything it
    /// finds in the 200-line scrape window; iOS caps here so a `tail -f`
    /// log doesn't produce a pill strip that scrolls for days.
    @AppStorage("urlTrayLimit") private var urlTrayLimit = 10
    /// Zoom level index into `ContentZoomLevel.allCases`. Persisted so the
    /// user's pick survives relaunch, and shared between portrait and
    /// landscape views so cycling in one affects both.
    @AppStorage("contentZoomLevel") private var contentZoomLevel = 1
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Live horizontal offset applied to the content panel while a
    /// window-cycle swipe is in progress. Dampened to 30% of the finger
    /// travel + capped at ±80pt so the card feels physical without
    /// yanking off-screen. Snaps back to 0 on gesture end if the threshold
    /// isn't hit. Zero when idle.
    @State private var swipeOffset: CGFloat = 0

    /// 0…1 normalized swipe magnitude, derived from swipeOffset. Used to
    /// drive the lift-off shadow and the scale-down so the card reads as
    /// "coming off the top of the deck" rather than just a flat slide.
    private var swipeProgress: CGFloat {
        min(1, abs(swipeOffset) / 80)
    }

    /// Which of the three render branches is active. Pinned by
    /// `InlineTerminalContentBranchTests` so future refactors don't silently
    /// flip the priority again.
    enum RenderBranch { case image, text, loading }

    /// Priority: image > text > loading. Image is the normal state and
    /// the one the state layer works hard to preserve (last-good screenshot
    /// caching so network blips don't kick us out). Text is the acceptable
    /// fallback when no screenshot has ever been received — user's stated
    /// preference is "plain text beats an empty Loading screen." Loading
    /// is the truly-no-content state (first connect, between window switches).
    ///
    /// The URL tray above the content still renders regardless of branch,
    /// so tappable URLs remain available even while waiting for a screenshot.
    static func branch(content: String, screenshot: String?) -> RenderBranch {
        if let screenshot, let data = Data(base64Encoded: screenshot),
           UIImage(data: data) != nil {
            return .image
        }
        if !content.isEmpty { return .text }
        return .loading
    }

    private var currentBranch: RenderBranch {
        Self.branch(content: content, screenshot: screenshot)
    }

    /// Tiny pill in the header showing which render branch is live.
    /// Horizontal scroll of tap-to-open URL pills. Renders above the
    /// terminal content, below the window-name header. Hidden entirely when
    /// `urls` is empty so zero-URL scrapes (the common case) don't burn
    /// vertical real estate. Each pill: tap → `UIApplication.shared.open`.
    @ViewBuilder
    private var urlTray: some View {
        // Keep the most recent N URLs — `TerminalURLExtractor` preserves
        // document order so suffix() == newest. Hide entirely when empty
        // or when the user has the tray turned off in Settings.
        let visible = Array(urls.suffix(max(1, urlTrayLimit)))
        if urlTrayEnabled && !visible.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(visible, id: \.self) { url in
                        Button {
                            if let u = URL(string: url) {
                                UIApplication.shared.open(u)
                            }
                        } label: {
                            Text(urlTrayLabel(for: url))
                                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(Color.cyan)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.cyan.opacity(0.15))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().stroke(Color.cyan.opacity(0.35), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .background(Color.white.opacity(0.03))
        }
    }

    /// Pill label — drop the scheme prefix for http(s)/mailto because it's
    /// visual noise that wastes pill width on a phone. The tap handler uses
    /// the full URL string so functionality is unchanged.
    private func urlTrayLabel(for url: String) -> String {
        if url.hasPrefix("https://") { return String(url.dropFirst("https://".count)) }
        if url.hasPrefix("http://")  { return String(url.dropFirst("http://".count)) }
        if url.hasPrefix("mailto:")  { return String(url.dropFirst("mailto:".count)) }
        return url
    }

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

            // URL tray above the content area so users can open URLs from
            // the screenshot (which is pixels and can't be tapped in-situ).
            urlTray

            // Three render branches, selected by `currentBranch` (pure fn
            // pinned by InlineTerminalContentBranchTests):
            //   .image   → SwiftUI Image inside ScrollView (zoom/pan, scroll-to-bottom)
            //   .text    → UITextView (own scroll, tap-to-open URL) — fallback
            //              when screenshot capture fails
            //   .loading → placeholder
            switch currentBranch {
            case .image:
                if let screenshot, let imageData = Data(base64Encoded: screenshot),
                   let uiImage = UIImage(data: imageData) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .id("bottom")
                        }
                        .onChange(of: screenshot) { _, _ in
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .text:
                LinkableTerminalText(content: content)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading:
                Text("Loading…")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
            }
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
        // Deck-of-cards lift: Y-axis 3D flip + slight scale-down + shadow
        // that grows with swipe magnitude. All three cues together read as
        // "card being lifted off the top of a stack," not just "view being
        // dragged sideways." Tuned subtle — max ~9° rotation, 3% shrink,
        // soft shadow at full swipe.
        .rotation3DEffect(
            .degrees(Double(swipeOffset) * 0.22),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.6
        )
        .scaleEffect(1 - swipeProgress * 0.03)
        .shadow(
            color: .black.opacity(0.45 * swipeProgress),
            radius: 14 * swipeProgress,
            x: swipeOffset * 0.2,
            y: 4 * swipeProgress
        )
        .offset(x: swipeOffset)
        .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.75), value: swipeOffset)
        .onAppear { onRefresh() }
        .onReceive(refreshTimer) { _ in onRefresh() }
        // Swipe left/right on the panel → cycle windows. Threshold 90pt +
        // 2:1 horizontal-to-vertical ratio so vertical scroll inside the
        // image ScrollView + pinch-zoom still work. `simultaneousGesture`
        // so we don't block the screenshot's own gesture stack.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    // Only show drag feedback when the motion is clearly
                    // horizontal — otherwise the panel twitches sideways
                    // when the user is trying to scroll the screenshot.
                    guard abs(dx) > abs(dy) * 2 else {
                        if swipeOffset != 0 { swipeOffset = 0 }
                        return
                    }
                    let damped = dx * 0.35
                    swipeOffset = max(-80, min(80, damped))
                }
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    swipeOffset = 0
                    guard abs(dx) > 90, abs(dx) > abs(dy) * 2 else { return }
                    // Left swipe (dx < 0) advances to the NEXT window,
                    // matching the iOS convention of "content slides left
                    // to reveal what comes next," like Photos or TabView.
                    onCycleWindow?(dx < 0 ? 1 : -1)
                }
        )
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
    case slash, plan, btw, compact, clearContext, prd
    case yes, no, one, two, three
    case esc, ctrlC, ctrlD, tab, backspace, clearInput
    case planMode, shiftTab

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .slash: return "/"
        case .plan: return "/plan"
        case .btw: return "/btw"
        case .compact: return "/compact"
        case .clearContext: return "/clear"
        case .prd: return "/prd"
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
        case .clearInput: return "Clear input"
        case .planMode: return "→Plan mode"
        case .shiftTab: return "Shift+Tab"
        }
    }

    /// Short label shown in the on-screen button itself (vs. `displayName`
    /// which shows in Settings).
    var label: String {
        switch self {
        case .slash: return "/"
        case .plan: return "/plan"
        case .btw: return "/btw"
        case .compact: return "/compact"
        case .clearContext: return "/clear"
        case .prd: return "/prd"
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
        case .clearInput: return ""
        case .planMode: return ""
        case .shiftTab: return ""
        }
    }

    var systemImage: String? {
        switch self {
        case .backspace: return "delete.left"
        case .esc: return "escape"
        case .ctrlC: return "xmark.octagon"
        case .ctrlD: return "eject"
        case .tab: return "arrow.right.to.line"
        case .clearInput: return "delete.left.fill"
        case .planMode: return "wand.and.stars"
        case .shiftTab: return "arrow.left.to.line"
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

    /// Logical grouping used by the on-screen quick-button row to position
    /// each cluster: slash commands left, answers centered (under the mic),
    /// keystrokes right.
    enum Category { case slash, answer, keystroke }

    var category: Category {
        switch self {
        case .slash, .plan, .btw, .compact, .clearContext, .prd, .planMode: return .slash
        case .yes, .no, .one, .two, .three: return .answer
        case .esc, .ctrlC, .ctrlD, .tab, .backspace, .clearInput, .shiftTab: return .keystroke
        }
    }

    var action: Action {
        switch self {
        // Bare "/" — opens Claude Code's slash command palette so the user
        // can pick one via autocomplete. No trailing space (unlike /plan,
        // /btw, /prd) so Claude's Ink dropdown fires immediately.
        case .slash: return .sendText("/", pressReturn: false)
        case .plan: return .sendText("/plan ", pressReturn: false)
        case .btw: return .sendText("/btw ", pressReturn: false)
        // /compact auto-submits because unlike /plan or /btw it doesn't
        // take a follow-up argument — it's a standalone command that
        // tells Claude "summarize the context now."
        case .compact: return .sendText("/compact", pressReturn: true)
        case .clearContext: return .sendText("/clear", pressReturn: true)
        // /prd takes a follow-up description, so don't auto-submit — same
        // pattern as /plan and /btw.
        case .prd: return .sendText("/prd ", pressReturn: false)
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
        case .clearInput: return .quickAction("clear_input")
        // Mac side reads the detected Claude mode for the target window and
        // sends just enough Shift+Tab presses to reach plan mode (cycle order:
        // normal → autoAccept → plan → normal). Falls back to an ErrorMessage
        // toast on the phone when the mode isn't yet detected.
        case .planMode: return .quickAction("set_plan_mode")
        // Raw Shift+Tab — manual fallback when mode auto-detect is unreliable
        // or the user wants to step through the cycle one mode at a time.
        case .shiftTab: return .quickAction("press_shift_tab")
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

extension Notification.Name {
    /// Posted by the `quip://perms` deep-link handler so MainiOSView can pop
    /// the SettingsSheet. Carries no payload — the sheet always opens to the
    /// Mac Permissions section (it's at the top).
    static let quipShowSettings = Notification.Name("quip.showSettings")
}

struct SettingsSheet: View {
    @Binding var enabledQuickButtonsRaw: String
    var client: WebSocketClient
    var pushRegistration: PushRegistrationService
    var macPermissions: MacPermissionsMessage?
    @AppStorage("tintContentBorder") private var tintContentBorder = true
    @AppStorage("urlTrayEnabled") private var urlTrayEnabled = true
    @AppStorage("urlTrayLimit") private var urlTrayLimit = 10
    @AppStorage("pushPaused") private var pushPaused = false
    @AppStorage("pushBannerEnabled") private var pushBannerEnabled = true
    @AppStorage("pushSound") private var pushSound = true
    @AppStorage("pushForegroundBanner") private var pushForegroundBanner = false
    @AppStorage("pushQuietHoursEnabled") private var quietHoursEnabled = false
    @AppStorage("pushQuietHoursStart") private var quietHoursStart = 22
    @AppStorage("pushQuietHoursEnd") private var quietHoursEnd = 7
    // Device-local only — Live Activities don't flow through the Mac's
    // APNs prefs, so no sendPrefs() wiring. The main app reads this
    // @AppStorage key too and gates its liveActivity.startOrUpdate calls.
    @AppStorage("liveActivitiesEnabled") private var liveActivitiesEnabled = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Mac Status — compact in the common all-granted case (single
                // green row), expands to the three-row detail only when
                // something's wrong or we're still waiting for the Mac to
                // report in. Saves two rows and a paragraph of footer copy
                // for the 99% of sessions where everything's fine.
                macPermsSection

                // Appearance — tight single section. URL tray limit stepper
                // sits inline behind the toggle so enabling the tray doesn't
                // spawn a second row.
                Section("Appearance") {
                    Toggle("Tint content panel border", isOn: $tintContentBorder)
                    HStack {
                        Toggle("URL tray", isOn: $urlTrayEnabled)
                        if urlTrayEnabled {
                            Stepper("\(urlTrayLimit)",
                                    value: $urlTrayLimit, in: 1...50)
                                .fixedSize()
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Notifications — one section. Kill switch on top; the
                // usual sub-toggles only matter if Pause All is off, so we
                // gate them behind it to cut visual noise. Quiet Hours
                // steppers only show when the toggle is on, same deal.
                // Kept tight: no secondary "status" footer unless the OS
                // hasn't granted permission — that's the one case worth
                // surfacing because push won't work at all.
                Section {
                    Toggle("Pause All", isOn: $pushPaused)
                    if !pushPaused {
                        Toggle("Banner", isOn: $pushBannerEnabled)
                        if pushBannerEnabled {
                            Toggle("Sound", isOn: $pushSound)
                            Toggle("Banner When App Open", isOn: $pushForegroundBanner)
                        }
                        Toggle("Live Activities", isOn: $liveActivitiesEnabled)
                        Toggle("Quiet Hours", isOn: $quietHoursEnabled)
                        if quietHoursEnabled {
                            Stepper("From \(formatHour(quietHoursStart))",
                                    value: $quietHoursStart, in: 0...23)
                            Stepper("Until \(formatHour(quietHoursEnd))",
                                    value: $quietHoursEnd, in: 0...23)
                        }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    if pushRegistration.deviceToken == nil {
                        Text("Notification permission not granted. Reconnect or check iOS Settings → Quip.")
                    }
                }
                .onChange(of: pushPaused) { _, _ in sendPrefs() }
                .onChange(of: pushBannerEnabled) { _, _ in sendPrefs() }
                .onChange(of: pushSound) { _, _ in sendPrefs() }
                .onChange(of: pushForegroundBanner) { _, _ in sendPrefs() }
                .onChange(of: quietHoursEnabled) { _, _ in sendPrefs() }
                .onChange(of: quietHoursStart) { _, _ in sendPrefs() }
                .onChange(of: quietHoursEnd) { _, _ in sendPrefs() }

                // Quick Buttons — moved behind a NavigationLink so the
                // ~18-chip grid doesn't pile on at the bottom of the main
                // Settings page. Enabled-count preview gives a one-glance
                // read on how many are active without drilling in.
                Section {
                    NavigationLink {
                        QuickButtonsSheet(enabledQuickButtonsRaw: $enabledQuickButtonsRaw)
                    } label: {
                        HStack {
                            Text("Quick Buttons")
                            Spacer()
                            Text("\(QuickButton.decode(enabledQuickButtonsRaw).count) enabled")
                                .foregroundStyle(.secondary)
                        }
                    }
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

    /// Mac Permissions top section. Three states, rendered at very different
    /// densities so the common case (everything green) doesn't eat rows:
    ///   - Waiting for Mac to report → placeholder row + footer
    ///   - All three granted → single "Mac permissions OK" row, no footer
    ///   - Any missing → full expanded detail + footer prompting user to tap
    /// The "tap a red row to open System Settings" pattern depends on the
    /// detail rows being visible, which is why we only expand when needed.
    @ViewBuilder
    private var macPermsSection: some View {
        Section {
            if let perms = macPermissions {
                let allGranted = perms.accessibility && perms.appleEvents && perms.screenRecording
                if allGranted {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.green)
                        Text("Mac permissions OK")
                        Spacer()
                    }
                } else {
                    macPermRow(name: "Accessibility",
                               icon: "accessibility",
                               granted: perms.accessibility,
                               pane: .accessibility)
                    macPermRow(name: "Automation (iTerm)",
                               icon: "terminal",
                               granted: perms.appleEvents,
                               pane: .automation)
                    macPermRow(name: "Screen Recording",
                               icon: "rectangle.dashed",
                               granted: perms.screenRecording,
                               pane: .screenRecording)
                }
            } else {
                HStack {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                    Text("Waiting for Mac…")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Mac Permissions")
        } footer: {
            if let perms = macPermissions,
               !(perms.accessibility && perms.appleEvents && perms.screenRecording) {
                Text("Tap a red row — Mac will pop the right System Settings pane open.")
            } else if macPermissions == nil {
                Text("If this never updates, the Mac may be on an older build that doesn't broadcast permission status.")
            }
        }
    }

    /// Single Mac-permission row. Green check when granted; red cross when not,
    /// and tapping a denied row asks the Mac to open the matching System Settings
    /// pane via `OpenMacSettingsPaneMessage`. Granted rows aren't tappable —
    /// nothing useful happens there and we don't want to bounce the Mac into
    /// Settings on accidental taps.
    @ViewBuilder
    private func macPermRow(name: String, icon: String, granted: Bool, pane: MacSettingsPane) -> some View {
        let row = HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(name)
            Spacer()
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(granted ? Color.green : Color.red)
            if !granted {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        if granted {
            row
        } else {
            Button { client.send(OpenMacSettingsPaneMessage(pane: pane)) } label: { row }
                .buttonStyle(.plain)
        }
    }

    /// Send the current settings state to the Mac so it can honor them
    /// at push-send time. Fires on every toggle change and from onAppear.
    /// No-op when we don't yet have a device token (nothing to key on
    /// from the Mac's perspective).
    fileprivate func sendPrefs() {
        guard let token = pushRegistration.deviceToken else { return }
        let msg = PushPreferencesMessage(
            deviceToken: token,
            paused: pushPaused,
            quietHoursStart: quietHoursEnabled ? quietHoursStart : nil,
            quietHoursEnd: quietHoursEnabled ? quietHoursEnd : nil,
            sound: pushSound,
            foregroundBanner: pushForegroundBanner,
            bannerEnabled: pushBannerEnabled,
            timeZone: TimeZone.current.identifier
        )
        client.send(msg)
    }

    /// 13 → "1 PM", 0 → "12 AM", 22 → "10 PM". Plain string for Steppers.
    fileprivate func formatHour(_ h: Int) -> String {
        let hh = h % 24
        let suffix = hh < 12 ? "AM" : "PM"
        let display = hh == 0 ? 12 : (hh > 12 ? hh - 12 : hh)
        return "\(display) \(suffix)"
    }

}

/// Quick Buttons detail page — lives behind a NavigationLink in SettingsSheet
/// instead of inlining the ~18-chip grid on the main Settings page. Keeps the
/// top-level Settings list scannable without losing the density the chip grid
/// provides here.
struct QuickButtonsSheet: View {
    @Binding var enabledQuickButtonsRaw: String

    var body: some View {
        List {
            Section {
                let columns = [GridItem(.adaptive(minimum: 100, maximum: 180), spacing: 6)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(QuickButton.allCases) { button in
                        chip(button)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Tap a chip to toggle it on/off. Enabled buttons show up in the row above the keyboard.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Quick Buttons")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func chip(_ button: QuickButton) -> some View {
        let isOn = QuickButton.decode(enabledQuickButtonsRaw).contains(button)
        Button {
            toggle(button)
        } label: {
            HStack(spacing: 4) {
                if let icon = button.systemImage {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                }
                Text(button.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
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

/// Tab selection for the Spawn Window sheet. "New" is the original path —
/// project directories the Mac reports — and "Attach Existing" is the new
/// flow that lets the user pick an iTerm window already open on the Mac.
/// Keeping them in one sheet (vs two separate buttons on the main bar) keeps
/// chrome off the main screen; both actions live behind the same "+" tap.
enum SpawnSheetTab: String, CaseIterable, Identifiable {
    case new = "New"
    case attach = "Attach Existing"
    var id: String { rawValue }
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
        ContentZoomLevel(rawValue: raw) ?? .fill
    }

    var next: Int {
        (rawValue + 1) % ContentZoomLevel.allCases.count
    }
}
