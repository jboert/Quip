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

    /// The notification delegate must exist before launch finishes, or an
    /// action tapped while the app is not running never reaches it (Q-57).
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = PushNotificationCenterDelegate.shared
        // Merges with the per-alert categories the service extension
        // registered (Q-60); a plain set here would wipe their buttons.
        WaitingNotificationCategory.register()
        return true
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

/// Pure helpers for mutating the per-windowId content state maps that
/// QA mode (and the inline single-window flow) read through. Pulled out
/// of MainiOSView so unit tests don't have to instantiate the whole view.
enum ContentMapMutations {
    /// Sticky writes for screenshots so a refresh whose capture transiently
    /// fails (Mac sends nil/empty) does not blank the pane. URL lists are
    /// optional for wire compatibility: nil means "older Mac omitted this
    /// field", while an explicit empty list means "current scrape has no URLs"
    /// and must clear the tray.
    static func applyContent(
        windowId: String,
        text: String?,
        screenshot: String?,
        urls: [String]?,
        into textMap: inout [String: String],
        _ screenshotMap: inout [String: String],
        _ urlsMap: inout [String: [String]]
    ) {
        if let text { textMap[windowId] = text }
        if let screenshot, !screenshot.isEmpty { screenshotMap[windowId] = screenshot }
        if let urls { urlsMap[windowId] = urls }
    }

    static func purgePairContent(
        pair: (String, String),
        from textMap: inout [String: String],
        _ screenshotMap: inout [String: String],
        _ urlsMap: inout [String: [String]]
    ) {
        for id in [pair.0, pair.1] {
            textMap.removeValue(forKey: id)
            screenshotMap.removeValue(forKey: id)
            urlsMap.removeValue(forKey: id)
        }
    }

    /// Keep the potentially large screenshot/text caches aligned with the
    /// current window snapshot. A window can disappear without entering QA
    /// mode (quit, Space change, or backend switch), so pair-only cleanup is
    /// not sufficient and would retain base64 screenshots forever.
    static func pruneToWindowIDs(
        _ activeIDs: Set<String>,
        textMap: inout [String: String],
        _ screenshotMap: inout [String: String],
        _ urlsMap: inout [String: [String]],
        _ updatedAtMap: inout [String: Date],
        _ autosuggestMap: inout [String: TerminalAutosuggest]
    ) {
        textMap.keys.filter { !activeIDs.contains($0) }.forEach { textMap.removeValue(forKey: $0) }
        screenshotMap.keys.filter { !activeIDs.contains($0) }.forEach { screenshotMap.removeValue(forKey: $0) }
        urlsMap.keys.filter { !activeIDs.contains($0) }.forEach { urlsMap.removeValue(forKey: $0) }
        updatedAtMap.keys.filter { !activeIDs.contains($0) }.forEach { updatedAtMap.removeValue(forKey: $0) }
        autosuggestMap.keys.filter { !activeIDs.contains($0) }.forEach { autosuggestMap.removeValue(forKey: $0) }
    }
}

@main
struct QuipApp: App {
    @UIApplicationDelegateAdaptor(AppOrientationDelegate.self) var appDelegate
    @State private var manager = BackendConnectionManager()
    /// Convenience: `client.send(...)` everywhere keeps working unchanged
    /// because the active session's client is what we want to talk to.
    private var client: WebSocketClient { manager.active.client }
    @State private var speech = SpeechService()
    @State private var volumeHandler = HardwareButtonHandler()
    @State private var bonjourBrowser = BonjourBrowser()
    @State private var pushRegistration = PushRegistrationService()
    @State private var attentionCenter = WindowAttentionCenter()
    private var pushDelegate: PushNotificationCenterDelegate { .shared }
    @State private var watchSync = WatchSyncService()
    @State private var liveActivity = LiveActivityService()
    @State private var prefsSync = PreferencesSyncService()

    // §6.1 prompt/button pack import. Same @AppStorage keys MainiOSView uses,
    // so a mutation here syncs to both views (and to the Mac via the snapshot).
    @AppStorage("quickSlotsJSON") private var quickSlotsJSON: String = ""
    @AppStorage("customButtonsJSON") private var customButtonsJSON: String = "[]"
    @AppStorage(LabsFlags.promptPackSharing) private var labsPromptPacks = false
    @State private var importablePack: ImportablePack?
    @State private var importPackErrorMsg: String?
    @State private var showImportPackError = false

    // Content-share intake: a `quip://share` deep link parks a parsed draft here
    // for review (US-004 renders it). Set only from a well-formed link; a
    // malformed link is a no-op and never touches selectedWindowId / showTextInput.
    @State private var pendingContentShare: PendingContentShare?

    @State private var windows: [WindowState] = []
    @State private var layoutReceived = false
    @State private var selectedWindowId: String?
    @State private var monitorName: String = "Mac"
    @State private var screenAspect: Double = 16.0 / 10.0
    /// Displays on the active Mac. Empty = one screen (or an older Mac build),
    /// which hides the screen chips entirely.
    @State private var displays: [DisplayState] = []
    @State private var spanAspect: Double = 16.0 / 10.0
    @State private var spaces: [SpaceState] = []
    @State private var selectedSpaceID: String?
    /// Chip selection: a `DisplayState.id`, or nil for "All screens".
    @State private var selectedDisplayID: String?
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
    @State private var terminalContentUpdatedAt: Date?
    // Per-windowId content maps — populated alongside the single-state properties
    // during the dual-state transition period. Task 5 migrates read sites to these.
    @State private var terminalContentTextById: [String: String] = [:]
    @State private var terminalContentScreenshotById: [String: String] = [:]
    @State private var terminalContentURLsById: [String: [String]] = [:]
    @State private var terminalContentUpdatedAtById: [String: Date] = [:]
    /// Per-window inline autosuggestion from the Mac's terminal_content
    /// broadcast (AutosuggestDetector) — the typed prefix and the ghost run.
    /// Gates the accept-autocomplete button AND is what the input row renders.
    /// Missing key = no suggestion (older Mac builds never send the field, and
    /// their flag-only broadcasts leave the button working with nothing to
    /// draw).
    @State private var terminalAutosuggestById: [String: TerminalAutosuggest] = [:]
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
    /// Press Return for the user once a dictation finishes. Off by default:
    /// the historical behaviour is to leave the transcript in the prompt so a
    /// long dictation can be read back before it is sent.
    @AppStorage("dictation.autoSend") private var dictationAutoSend = false
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
    /// (wishlist §15.) Default false → only the currently-selected
    /// window's `waiting_for_input` events push. True → every enabled
    /// window's transitions push. Synced to Mac via PushPreferencesMessage.
    @AppStorage("pushNotifyAllWindows") private var pushNotifyAllWindows = false
    /// Manual override for the system color scheme. "auto" follows
    /// `UITraitCollection.userInterfaceStyle`; "light" / "dark" pin
    /// the app regardless of system. Read at root via the
    /// `appearancePreferred` computed `ColorScheme?` and applied via
    /// `.preferredColorScheme(...)` on the WindowGroup root view.
    @AppStorage("appearance.mode") private var appearanceModeRaw: String = "auto"
    /// (wishlist §B16.) When true, incoming `frontmost_changed` from the
    /// Mac auto-retargets `selectedWindowId` so image / text sends land in
    /// whatever window the user is currently looking at on the Mac.
    /// Manually tapping a window card pins (sets this to false); the user
    /// re-enables follow-mode via the Auto pill in the picker row.
    /// Default true — matches the user's expectation that "the phone
    /// follows the Mac" without an explicit step.
    @AppStorage("followFrontmost") private var followFrontmost = true
    /// The active Mac's last `frontmost_changed`, for LandingPolicy step 2.
    /// Cleared on backend switch: it belongs to the Mac that sent it.
    @State private var macFrontmostId: String?
    private var appearancePreferred: ColorScheme? {
        switch appearanceModeRaw {
        case "light": return .light
        case "dark": return .dark
        default: return nil // auto
        }
    }
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
                manager: manager,
                speech: speech,
                bonjourBrowser: bonjourBrowser,
                windows: $windows,
                layoutReceived: $layoutReceived,
                selectedWindowId: $selectedWindowId,
                isRecording: $isRecording,
                terminalContentText: $terminalContentText,
                terminalContentScreenshot: $terminalContentScreenshot,
                terminalContentURLs: $terminalContentURLs,
                terminalContentWindowId: $terminalContentWindowId,
                terminalContentUpdatedAt: $terminalContentUpdatedAt,
                terminalContentTextById: $terminalContentTextById,
                terminalContentScreenshotById: $terminalContentScreenshotById,
                terminalContentURLsById: $terminalContentURLsById,
                terminalContentUpdatedAtById: $terminalContentUpdatedAtById,
                terminalAutosuggestById: $terminalAutosuggestById,
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
                displays: displays,
                spanAspect: spanAspect,
                spaces: spaces,
                selectedSpaceID: $selectedSpaceID,
                selectedDisplayID: $selectedDisplayID,
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
            .preferredColorScheme(appearancePreferred)
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
                // (wishlist §15 v2 / Watch-actions path A, Q-57.) Lock-screen
                // buttons and the Reply field land in PushAnswerQueue; it
                // sends over the active socket, or wakes one and sends on
                // auth, so an answer given while the app was suspended is
                // not lost.
                pushDelegate.onAnswerQueued = { windowId in
                    attentionCenter.clearAttention(for: windowId)
                }
                PushAnswerQueue.shared.deliver = { answer in
                    guard client.isAuthenticated else { return false }
                    if let text = answer.text {
                        return client.send(SendTextMessage(windowId: answer.windowId, text: text, pressReturn: true))
                    }
                    // quick_action carries the prompt fingerprint, so the Mac
                    // re-validates before injecting (§3.2).
                    return client.send(QuickActionMessage(windowId: answer.windowId,
                                                          action: answer.action ?? "",
                                                          promptFingerprint: answer.promptFingerprint))
                }
                PushAnswerQueue.shared.wake = { manager.resumeAll() }
                PushAnswerQueue.shared.flush()
                // Register the category set so iOS knows which actions to
                // surface for any push whose `aps.category` matches.
                // Idempotent; safe to call on every cold start.
                WaitingNotificationCategory.register()
            }
            .onChange(of: selectedWindowId) { _, newId in
                // User engaged with a window — clear its attention flag so
                // the pulsing dot and badge count go quiet. Fires from every
                // selection path: tap, Mac echo, deep-link tap, etc.
                if let newId { attentionCenter.clearAttention(for: newId) }
                // Remember it so a reconnect (e.g. after backgrounding) comes
                // back to this window instead of windows.first.
                if let newId, !manager.activeBackendID.isEmpty {
                    WindowSelectionMemory.remember(newId, forBackendId: manager.activeBackendID)
                }
            }
            .onChange(of: manager.activeBackendID) { _, _ in
                // Active backend changed — copy the new session's slice into
                // the global @State so the UI shows that backend's data
                // immediately. Hot model: the slice was kept up to date in
                // the background, so this is a sub-frame view swap.
                let s = manager.active
                macFrontmostId = nil
                windows = s.windows
                selectedWindowId = s.selectedWindowId
                monitorName = s.monitorName
                screenAspect = s.screenAspect
                displays = s.displays
                spanAspect = s.spanAspect
                spaces = s.spaces
                selectedSpaceID = SpaceActivity.selectionSurvivingUpdate(selectedSpaceID,
                                                                         incoming: s.spaces)
                selectedDisplayID = s.selectedDisplayID
                ContentMapMutations.pruneToWindowIDs(
                    Set(s.windows.map(\.id)),
                    textMap: &terminalContentTextById,
                    &terminalContentScreenshotById,
                    &terminalContentURLsById,
                    &terminalContentUpdatedAtById,
                    &terminalAutosuggestById
                )
                terminalContentText = s.terminalContentText
                terminalContentScreenshot = s.terminalContentScreenshot
                terminalContentURLs = s.terminalContentURLs
                terminalContentWindowId = s.terminalContentWindowId
                projectDirectories = s.projectDirectories
                iTermScanResults = s.iTermScanResults
                macPermissions = s.macPermissions
                ttsOverlayTexts = s.ttsOverlayTexts
                // Re-run the resolver attach so the freshly active client
                // gets its onTranscriptResult callback wired up. The
                // resolver closure itself always returns manager.active.client
                // so it stays correct across swaps.
                speech.attachWebSocketResolver { [manager] in manager.active.client }
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
                // §6.1 — "Open in Quip" for a shared .quippack file. Handle
                // before the quip:// scheme guard (file URLs have no scheme).
                if url.isFileURL && url.pathExtension == SharedPromptPack.fileExtension {
                    handleIncomingPack(url)
                    return
                }
                // Deep link from the Live Activity island / lock screen:
                //   quip://window/<windowId> — select that window + open input
                //   quip://perms            — pop the SettingsSheet open (Mac
                //                             perms section is at the top)
                guard url.scheme?.lowercased() == "quip" else { return }
                // US-114 — quip://broadcast?text=…|prompt=… opens the Broadcast
                // sheet and never sends. Checked first: the legacy quip://<id>
                // form would read "broadcast" as a window id.
                if let link = BroadcastLink.parse(url) {
                    NotificationCenter.default.post(name: .quipOpenBroadcast, object: link)
                    return
                }
                // Classify once (pure); the side effects stay here. A malformed
                // link classifies as `.none` and is a no-op — it never changes
                // selectedWindowId or opens the text input.
                switch ContentShareDeepLink.route(for: url) {
                case .pair:
                    // §50 — tap-to-pair from a shared `quip://pair?url=…&pin=…`
                    // link (AirDrop/Messages/Mail), so remote users never need
                    // the on-screen QR or the native Camera. Decode here, then
                    // hand off to MainiOSView's `applyPairingPayload` (which owns
                    // the connect path) via `.quipApplyPairing`. Decode failure
                    // is a no-op.
                    if let payload = PairingPayload.decode(url.absoluteString) {
                        NotificationCenter.default.post(name: .quipApplyPairing, object: payload)
                    }
                case .perms:
                    NotificationCenter.default.post(name: .quipShowSettings, object: nil)
                case .window(let windowId):
                    selectedWindowId = windowId
                    attentionCenter.clearAttention(for: windowId)
                    showTextInput = true
                    client.send(SelectWindowMessage(windowId: windowId))
                case .share(let draft, let mode):
                    // Park the draft for review (US-004). Do NOT select a window
                    // or open the text input — nothing is sent until reviewed.
                    pendingContentShare = PendingContentShare(draft: draft, mode: mode)
                case .none:
                    return
                }
            }
            .sheet(item: $importablePack) { item in
                ImportPackSheet(pack: item.pack, plan: importPlan(for: item.pack)) { applyImportedPack(item.pack) }
            }
            .sheet(item: $pendingContentShare) { share in
                // US-004/US-005 — review a parked quip://share draft, then ship
                // it through the same send_text path as a typed prompt. Send is
                // gated on a selected window + a live connection
                // (ContentShareReviewState.canSend).
                ContentShareReviewSheet(
                    pending: share,
                    windows: windows,
                    isConnected: client.isConnected,
                    initialWindowId: selectedWindowId,
                    onSend: { windowId, mode in
                        // flushPendingImage fires the callback immediately when
                        // no image is queued, so the image pipeline is only
                        // touched when something is actually pending.
                        let message = ContentShareSend.message(
                            for: share.draft, mode: mode, windowId: windowId)
                        flushPendingImage(windowId: windowId) { [client] in
                            client.send(message)
                        }
                        ContentShareSend.recordRecent(share.draft)
                        selectedWindowId = windowId
                        pendingContentShare = nil
                    },
                    onCancel: {
                        // Dismiss without touching selectedWindowId or sending.
                        pendingContentShare = nil
                    }
                )
            }
            .alert("Couldn't import pack", isPresented: $showImportPackError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importPackErrorMsg ?? "")
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                // Always call resumeAfterBackground so the volume KVO observer
                // gets re-armed (it was torn down in pauseMonitoring on enter-
                // background). The previous `!speech.isSpeaking` guard left
                // PTT dead whenever the user backgrounded mid-TTS — the
                // observer stayed nil and vol-down did nothing on return.
                // resumeAfterBackground itself avoids fighting an active TTS
                // playback because primeRailIfNeeded only nudges volume when
                // parked on a rail.
                volumeHandler.resumeAfterBackground()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                // Buy ~30s of background execution so a quick app switch doesn't
                // suspend the network stack and stale the WebSocket. Hot model
                // means every paired backend's socket gets the same grace.
                manager.suspendAll()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                // Pause (not stopMonitoring) so windowCount survives. Full
                // stopMonitoring zeroes windowCount, which left PTT dead on
                // resume until the next Mac layout_update re-armed it. The
                // pauseMonitoring path drops just the KVO observer; the next
                // foreground hook re-arms with the cached windowCount.
                volumeHandler.pauseMonitoring()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                // Probe every paired backend's socket on return; force-reconnect
                // with reset backoff if the probe doesn't pong within 2s.
                manager.resumeAll()
            }
        }
    }

    /// True when the current wall-clock hour falls inside the user's
    // MARK: - §6.1 Prompt/button pack import

    /// Decode an incoming `.quippack` file and present the import preview.
    /// Never applies silently; bad / newer / empty files surface an alert.
    private func handleIncomingPack(_ url: URL) {
        guard labsPromptPacks else {
            importPackErrorMsg = "Enable Settings → Quip Labs → Prompt & button packs to import."
            showImportPackError = true
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let pack = try SharedPromptPack.decode(data)
            guard !pack.isEmpty else {
                importPackErrorMsg = "That pack has no prompts or buttons."
                showImportPackError = true
                return
            }
            importablePack = ImportablePack(pack: pack)
        } catch SharedPromptPack.PackError.unsupportedSchema {
            importPackErrorMsg = "This pack was made by a newer version of Quip."
            showImportPackError = true
        } catch {
            importPackErrorMsg = "That file isn't a valid Quip pack."
            showImportPackError = true
        }
    }

    /// What importing `pack` would add right now, given the phone's current
    /// prompt library and custom buttons (Q-27b).
    private func importPlan(for pack: SharedPromptPack) -> SharedPromptPack.ImportPlan {
        SharedPromptPack.importPlan(for: pack,
                                    existingPrompts: client.promptLibrary,
                                    existingButtons: CustomButtonStore.decode(customButtonsJSON))
    }

    /// Apply a confirmed pack: prompts → Mac via PutPromptMessage (non-colliding
    /// ids), buttons → appended locally with fresh UUIDs (auto-syncs to Mac via
    /// the preferences snapshot). Anything already installed is skipped, so
    /// importing the same pack twice no longer duplicates it (Q-27b).
    private func applyImportedPack(_ pack: SharedPromptPack) {
        let plan = importPlan(for: pack)
        for p in plan.prompts {
            client.send(PutPromptMessage(id: p.id, label: p.label, body: p.body,
                                         tags: p.tags, targetAgent: p.targetAgent, description: p.description))
        }
        if !plan.buttons.isEmpty {
            var defs = CustomButtonStore.decode(customButtonsJSON)
            var slotList = QuickSlotStore.decode(quickSlotsJSON)
            for r in plan.buttons {
                defs.append(r)
                slotList.append(.custom(r.id))
            }
            customButtonsJSON = CustomButtonStore.encode(defs)
            quickSlotsJSON = QuickSlotStore.encode(slotList)
        }
    }

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
        // Hot model: load persisted paired backends, then `bootstrap()`
        // spawns one wired+connected `WebSocketClient` per entry. Each
        // session accumulates its own state slice; switching active backend
        // is just a UI flip. Note: manager hooks (set below) are wired to
        // the manager BEFORE bootstrap fires its first message routes —
        // SwiftUI runs `setup()` synchronously on body composition, so the
        // hooks are in place before any network frame arrives.
        manager.loadPaired()

        speech.requestAuthorization()
        // Resolver form: speech grabs the *current* active client at every
        // PTT press. The prior `attachWebSocket(client)` form weak-pointed
        // at whatever `manager.active.client` was at setup time — which,
        // before `manager.bootstrap()` ran, was the placeholder session's
        // client. Once the placeholder was released, speech.webSocket was
        // permanently nil and PTT silently fell to .local with no captions.
        speech.attachWebSocketResolver { [manager] in manager.active.client }

        // Hot model: the manager's `wire(session:)` already maintained each
        // session's slice (windows, monitorName, terminalContent, etc.). The
        // host hooks below only fire global side-effects + mirror into
        // QuipApp's @State for the *active* session — background sessions
        // accumulate state silently in their own slice so a switch is instant.
        manager.onLayoutUpdate = { session, update in
            guard session.backendID == manager.activeBackendID else { return }
            DispatchQueue.main.async {
                let wasEmpty = windows.isEmpty
                windows = update.windows
                layoutReceived = true
                ContentMapMutations.pruneToWindowIDs(
                    Set(update.windows.map(\.id)),
                    textMap: &terminalContentTextById,
                    &terminalContentScreenshotById,
                    &terminalContentURLsById,
                    &terminalContentUpdatedAtById,
                    &terminalAutosuggestById
                )
                monitorName = update.monitor
                if let a = update.screenAspect, a > 0 { screenAspect = a }
                if let d = update.displays { displays = d }
                if let span = update.spanAspect, span > 0 { spanAspect = span }
                if let incomingSpaces = update.spaces {
                    spaces = incomingSpaces
                    selectedSpaceID = SpaceActivity.selectionSurvivingUpdate(selectedSpaceID,
                                                                             incoming: incomingSpaces)
                }
                // The manager already dropped a filter pointing at an
                // unplugged monitor; mirror its verdict so the chips and the
                // canvas can't disagree about which screen is showing.
                selectedDisplayID = manager.active.selectedDisplayID
                volumeHandler.startMonitoring(windowCount: update.windows.count)
                // Push window snapshot to the paired Apple Watch (no-op if
                // no watch is paired or the app isn't installed).
                watchSync.push(windows: update.windows.map {
                    WatchWindowSyncEntry(id: $0.id, name: $0.name,
                                         state: $0.state, claudeMode: $0.claudeMode)
                })
                if wasEmpty && !update.windows.isEmpty {
                    AppOrientationDelegate.allowAllOrientations = true
                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .allButUpsideDown))
                    }
                    UIViewController.attemptRotationToDeviceOrientation()
                }
                // Auto-pick a window on the first layout_update after a fresh
                // launch / fresh connect, and when the selected window has
                // vanished. Without a selection the user opens the app, sees
                // windows, taps mic — and PTT silently no-ops because
                // `startRecording` gates on `selectedWindowId != nil` (the
                // on-screen mic AND the hardware volume-down path). Which
                // window is LandingPolicy's call (Q-88 §3): follow the Mac,
                // else the window the user was last in, else the one before
                // it, else windows.first. One select_window at most.
                let outcome = LandingPolicy.afterLayout(
                    selected: selectedWindowId, wasEmpty: wasEmpty,
                    LandingPolicy.Input(
                        followFrontmost: followFrontmost && manager.active.qaPair == nil,
                        macFrontmost: macFrontmostId,
                        recency: WindowSelectionMemory.recent(forBackendId: session.backendID),
                        windows: update.windows.map(\.id)))
                selectedWindowId = outcome.selected
                if let reason = outcome.reason {
                    PhoneLog.log("landing reason=\(reason.rawValue)")
                }
                if let wid = outcome.send {
                    session.client.send(SelectWindowMessage(windowId: wid))
                }
            }
        }

        manager.onSelectWindow = { session, windowId in
            guard session.backendID == manager.activeBackendID else { return }
            DispatchQueue.main.async {
                guard windows.contains(where: { $0.id == windowId }) else { return }
                selectedWindowId = windowId
            }
        }

        // (wishlist §B16.) Mac broadcasts its current frontmost ManagedWindow.id
        // on every cross-app activation + every 400ms within-app poll. When the
        // user has the Auto pref enabled AND the broadcast id is in our current
        // window list, retarget. nil broadcasts (frontmost is something Quip
        // doesn't track — Finder, Mail, etc.) are ignored so the user's last
        // terminal stays selected until focus returns to a tracked window.
        manager.onFrontmostChanged = { session, windowId in
            guard session.backendID == manager.activeBackendID else { return }
            DispatchQueue.main.async {
                macFrontmostId = windowId
                // QA mode owns selection between the pair halves — frontmost autonomy here would yank selection out of the pane.
                guard manager.active.qaPair == nil else { return }
                guard followFrontmost else { return }
                guard let wid = windowId,
                      windows.contains(where: { $0.id == wid }) else { return }
                if selectedWindowId == wid { return }
                selectedWindowId = wid
                session.client.send(SelectWindowMessage(windowId: wid))
            }
        }

        manager.onProjectDirectories = { session, dirs in
            guard session.backendID == manager.activeBackendID else { return }
            DispatchQueue.main.async { projectDirectories = dirs }
        }

        manager.onITermWindowList = { session, infos in
            guard session.backendID == manager.activeBackendID else { return }
            DispatchQueue.main.async { iTermScanResults = infos }
        }

        manager.onError = { session, reason in
            guard session.backendID == manager.activeBackendID else { return }
            DispatchQueue.main.async {
                // A refused lock-screen answer has no toast to land on (Q-57).
                PushAnswerQueue.shared.promptChanged(
                    reason, appIsActive: UIApplication.shared.applicationState == .active)
                errorToast = reason
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if errorToast == reason { errorToast = nil }
                }
            }
        }

        // US-004 — swrm "story started" card. MVP surfaces it through the
        // existing toast banner (title + project); a dedicated styled card is
        // later polish. Fires for the active session only, like the others.
        manager.onSwrmStoryStarted = { session, msg in
            guard session.backendID == manager.activeBackendID else { return }
            DispatchQueue.main.async {
                let toast = "swrm ▶ \(msg.title) · \(msg.project)"
                errorToast = toast
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if errorToast == toast { errorToast = nil }
                }
            }
        }

        // Task 16 — QA pair invalidated by Mac (the paired window closed
        // or otherwise vanished). `BackendConnectionManager.wire()` has
        // already nilled `session.qaPair`, so the conditional in
        // MainiOSView's body falls back to the regular grid; this hook
        // just surfaces a user-facing toast so the user knows why the QA
        // layout disappeared.
        manager.onQAPairLost = { session, lostPair, missingId, _ in
            guard session.backendID == manager.activeBackendID else { return }
            DispatchQueue.main.async {
                if let lostPair {
                    ContentMapMutations.purgePairContent(
                        pair: (lostPair.targetId, lostPair.terminalId),
                        from: &terminalContentTextById,
                        &terminalContentScreenshotById,
                        &terminalContentURLsById
                    )
                }
                let appName = windows.first(where: { $0.id == missingId })?.app ?? "Window"
                let reason = "\(appName) closed. Exited QA mode."
                errorToast = reason
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if errorToast == reason { errorToast = nil }
                }
            }
        }

        manager.onStateChange = { session, windowId, newState in
            guard session.backendID == manager.activeBackendID else { return }
            DispatchQueue.main.async {
                if let i = windows.firstIndex(where: { $0.id == windowId }) {
                    let w = windows[i]
                    windows[i] = WindowState(
                        id: w.id, name: w.name, app: w.app, folder: w.folder, enabled: w.enabled,
                        frame: w.frame, state: newState, color: w.color,
                        isThinking: w.isThinking, project: w.project
                    )
                    if windowId == selectedWindowId, liveActivitiesEnabled {
                        let islandState: String? = switch newState {
                        case "thinking": "thinking"
                        case "waiting_for_input": "waiting"
                        default: nil
                        }
                        if let islandState, !isInQuietHoursNow() {
                            liveActivity.startOrUpdate(windowId: windowId, windowName: w.name, state: islandState)
                        } else if islandState == nil {
                            liveActivity.end(windowId: windowId)
                        }
                    }
                }
                // Push the updated snapshot to the watch so it can vibrate
                // on the waiting_for_input transition. push() dedupes, so
                // a no-change layout poll doesn't burn WCSession budget.
                watchSync.push(windows: windows.map {
                    WatchWindowSyncEntry(id: $0.id, name: $0.name,
                                         state: $0.state, claudeMode: $0.claudeMode)
                })
            }
        }

        volumeHandler.onSelectionChanged = { index in
            DispatchQueue.main.async {
                // Volume-button cycling is suppressed in QA mode for the same
                // reason cycleWindow is — pair scope must stay locked. Otherwise
                // a volume cycle would change selectedWindowId out from under the
                // pair and the second pane would go stale.
                if manager.active.qaPair != nil { return }
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

        manager.onTerminalContent = { session, windowId, content, screenshot, urls, autosuggest in
            guard session.backendID == manager.activeBackendID else { return }
            DispatchQueue.main.async {
                let receivedAt = Date()
                terminalContentWindowId = windowId
                terminalContentText = content
                terminalContentUpdatedAt = receivedAt
                terminalContentUpdatedAtById[windowId] = receivedAt
                terminalAutosuggestById[windowId] = autosuggest
                if let screenshot, !screenshot.isEmpty {
                    terminalContentScreenshot = screenshot
                }
                if let urls {
                    terminalContentURLs = urls
                }
                // Per-windowId map writes (dual-state: single-state reads still active
                // in Task 4; Task 5 migrates read sites to use these maps instead).
                ContentMapMutations.applyContent(
                    windowId: windowId,
                    text: content,
                    screenshot: screenshot.flatMap { $0.isEmpty ? nil : $0 },
                    urls: urls,
                    into: &terminalContentTextById,
                    &terminalContentScreenshotById,
                    &terminalContentURLsById
                )
            }
        }

        manager.onMacPermissions = { session, snapshot in
            guard session.backendID == manager.activeBackendID else { return }
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

        manager.onOutputDelta = { session, windowId, windowName, text, isFinal in
            guard session.backendID == manager.activeBackendID else { return }
            DispatchQueue.main.async {
                guard ttsEnabled else { return }
                ttsOverlayTexts[windowId] = text
            }
        }

        manager.onTTSAudio = { session, windowId, windowName, sessionId, sequence, isFinal, wavData in
            guard session.backendID == manager.activeBackendID else { return }
            DispatchQueue.main.async {
                guard ttsEnabled else { return }
                speech.enqueueAudio(wavData, windowId: windowId, sessionId: sessionId, isFinal: isFinal)
            }
        }

        manager.onAuthRequired = { session in
            guard session.backendID == manager.activeBackendID else { return }
            DispatchQueue.main.async {
                pinText = ""
                showPINEntry = true
            }
        }

        manager.onAuthResult = { session, success, error in
            // Read the PIN now, not after the hop below: a device_identity
            // merge can disconnect this session's client first, which
            // clears it.
            let validatedPIN = success ? session.client.sessionPIN : nil
            DispatchQueue.main.async {
                // Persist the just-validated PIN so the next launch (and
                // background reconnects) can auto-auth without prompting,
                // under the row that survives for this session: by now
                // device_identity may have rekeyed or merged it, which used
                // to skip this write or aim it at a deleted row (US-005).
                if let validatedPIN {
                    manager.persistValidatedPIN(validatedPIN, for: session)
                }
                // Compare the row that survives for this session, not its
                // id at auth time: device_identity usually rekeys or merges a
                // first pairing before this hop, which skipped hiding the PIN
                // sheet, push registration and the prefs restore.
                guard manager.survivingBackendID(for: session.backendID) == manager.activeBackendID else { return }
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
                                timeZone: TimeZone.current.identifier,
                                notifyAllWindows: ud.bool(forKey: "pushNotifyAllWindows"),
                                showPromptText: (ud.object(forKey: "pushShowPromptText") as? Bool) ?? true
                            )
                            client.send(prefs)
                        }
                    }
                    // Ask the Mac for our backed-up preferences. If this is a
                    // fresh reinstall, the Mac will push back whatever we last
                    // synced; otherwise it'll send an empty snapshot and the
                    // local UserDefaults stay as-is.
                    prefsSync.requestRestore()
                } else {
                    // A saved PIN the Mac no longer accepts used to leave the
                    // bar on "Authenticating…" with nothing to type into;
                    // the field only appeared on the next tap in the picker.
                    pinText = ""
                    showPINEntry = true
                }
            }
        }

        manager.onPreferencesRestore = { session, snapshot in
            guard session.backendID == manager.activeBackendID else { return }
            DispatchQueue.main.async {
                prefsSync.applyRestore(snapshot)
            }
        }

        // Connection memory is merged (not clobbered) into live state — the
        // backup restores paired backends + recent LANs across reinstalls.
        prefsSync.onRestorePaired = { [manager] json, activeID in
            DispatchQueue.main.async {
                manager.mergeRestoredBackends(json, activeID: activeID)
            }
        }
        prefsSync.onRestoreRecents = { json in
            DispatchQueue.main.async {
                // Recents live in MainiOSView's @State; merge at the UserDefaults
                // key it's backed by (@AppStorage "recentConnectionsData") so the
                // connect bar re-reads the union on its next appear. cap 10 mirrors
                // MainiOSView.maxConnections.
                let d = UserDefaults.standard
                guard let data = json.data(using: .utf8) else {
                    print("[Quip][Connections] restoreRecents FAILED: payload is not valid UTF-8 — recents NOT restored from Mac")
                    return
                }
                let restored: [SavedConnection]
                do {
                    restored = try JSONDecoder().decode([SavedConnection].self, from: data)
                } catch {
                    print("[Quip][Connections] restoreRecents FAILED bytes=\(data.count) err=\(error) — recents NOT restored from Mac")
                    return
                }
                // Empty payload is legitimate (Mac has no backup for this device).
                guard !restored.isEmpty else { return }
                let existing: [SavedConnection]
                if let raw = d.data(forKey: "recentConnectionsData"), !raw.isEmpty {
                    do {
                        existing = try JSONDecoder().decode([SavedConnection].self, from: raw)
                    } catch {
                        // Local blob is corrupt. Don't abort the restore — the Mac's
                        // copy is the better source — but say so, because the union
                        // silently drops whatever was in the local list.
                        print("[Quip][Connections] restoreRecents: local recents blob corrupt (bytes=\(raw.count), err=\(error)) — merging Mac copy over it")
                        existing = []
                    }
                } else {
                    existing = []
                }
                let merged = SavedConnection.mergedRecents(existing: existing, incoming: restored, cap: 10)
                do {
                    d.set(try JSONEncoder().encode(merged), forKey: "recentConnectionsData")
                } catch {
                    print("[Quip][Connections] restoreRecents FAILED to persist merge count=\(merged.count) err=\(error) — recents will be gone on next launch")
                }
            }
        }

        // Wire the sync service to actually transmit via the WebSocket. The
        // closure dynamically resolves `manager.active.client` each call, so
        // it always targets the current active backend even after a swap.
        prefsSync.send = { [manager] data in
            manager.active.client.sendRaw(data)
        }
        prefsSync.localOnlyPromptIDs = { [manager] in
            PromptPrivacy.localOnlyIDs(manager.active.client.promptLibrary)
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
        speech.startObservingInterruptions()

        // All host hooks wired. Now spawn one client per paired backend and
        // kick off auto-connect for any with a Keychain PIN. Background
        // backends connect silently — their slice updates don't fan out to
        // global @State because the gates above test active id.
        manager.bootstrap()
    }

    @MainActor
    private func startRecording() {
        guard let windowId = selectedWindowId else {
            // Visible failure beats silent no-op. Warning haptic + log so the
            // user knows the tap registered but the precondition (window
            // selected) wasn't met. Print survives `devicectl --console` per
            // memory `reference_ios_device_log_capture.md`.
            print("[Quip][PTT] startRecording bail: selectedWindowId=nil (windows=\(windows.count))")
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        // Pin the windowId for this recording — stopRecording must not re-read
        // selectedWindowId, because a mid-recording select_window push or a
        // layout-update reassignment can change it underneath us.
        guard speech.startRecording() else {
            print("[Quip][PTT] startRecording bail: speech service rejected start")
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        pttTracker.begin(windowId: windowId)
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
        // the Mac. `pressReturn: false` keeps it in the input line rather
        // than submitting, so a long dictation shows up verbatim in the
        // terminal (and thus in the phone's content panel via the next
        // refresh) and the user hits Return when they're ready — the default.
        // With "Auto-send dictation" on, Return is pressed for them instead,
        // which is what makes hands-free work end to end.
        //
        // Trim trailing whitespace/newlines: a stray \n typed into Claude's
        // box would get swallowed by the box as a newline rather than
        // treated as "submit," and it breaks the render.
        let windowId = pttTracker.end()
        // Read the toggle now, on the main actor, rather than inside the
        // completion that fires from the speech worker.
        let autoSend = dictationAutoSend
        // Defer SendTextMessage until the speech worker finishes its 300ms
        // trailing flush — otherwise the user's last word (captured during
        // the flush window) never makes it into the prompt.
        speech.stopRecording { finalText in
            let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("[Quip] stopRecording: windowId=%@, text='%@' (length=%d)", windowId ?? "nil", text, text.count)
            guard let windowId else { return }
            flushPendingImage(windowId: windowId) { [client] in
                client.send(STTStateMessage.ended(windowId: windowId))
                if !text.isEmpty {
                    client.send(SendTextMessage(windowId: windowId, text: text,
                                                pressReturn: autoSend))
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

/// Single-line capsule descriptor for the PTT health banner rendered just
/// above the main row. Surfaces path-degraded states (Whisper offline,
/// mid-press disconnect, model warming up) that were previously NSLog-only
/// or buried in Settings → Diagnostics. Built by
/// `MainiOSView.classifyPTTBanner(...)`. (GH H.)
struct PTTBannerInfo: Equatable {
    let icon: String
    let message: String
    let tint: Color
}

/// Top-bar connection-status pill. Replaces the prior binary
/// (Connected / Connecting…) with five distinguishable states so the
/// user can spot stalled / auth-failed / unpaired without digging into
/// Settings or the picker. Pure classifier on WebSocketClient state +
/// the paired-backends count. (§K.)
enum TopBarStatus: String, Equatable, CaseIterable {
    case unpaired
    case connected
    case connecting
    case authFailed
    case stalled

    var label: String {
        switch self {
        case .unpaired:    return "Not paired"
        case .connected:   return "Connected"
        case .connecting:  return "Connecting\u{2026}"
        case .authFailed:  return "Auth failed"
        case .stalled:     return "Reconnecting\u{2026}"
        }
    }

    func dot(colors: QuipColors) -> Color {
        switch self {
        case .unpaired:    return .secondary.opacity(0.4)
        case .connected:   return colors.statusConnected
        case .connecting:  return colors.statusConnecting
        case .authFailed:  return .orange
        case .stalled:     return .red.opacity(0.7)
        }
    }

    /// Pure classifier so unit tests don't need a SwiftUI view + a live
    /// WebSocketClient. Priority order matters: a connected client
    /// supersedes everything; a stalled lastError outranks the
    /// generic "Connecting…" because the user wants to see that
    /// something's actively wrong.
    static func classify(isConnected: Bool,
                          isConnecting: Bool,
                          isAuthenticated: Bool,
                          lastError: String?,
                          hasPaired: Bool) -> TopBarStatus {
        if isConnected { return .connected }
        if !hasPaired { return .unpaired }
        if let err = lastError {
            let lower = err.lowercased()
            if lower.contains("auth") || lower.contains("pin") {
                return .authFailed
            }
            if lower.contains("stalled") || lower.contains("no pong") || lower.contains("timed out") {
                return .stalled
            }
        }
        if isConnecting { return .connecting }
        // Catch-all for "not connecting, not connected, paired, no
        // explicit error" — usually transient between a forced
        // disconnect and the auto-reconnect kicking in.
        return .stalled
    }

    /// Structured-reason variant. Same priority order as the lastError
    /// classifier but reads the typed `DisconnectReason` instead of
    /// keyword-matching a free-form string. Use this when the call site
    /// has access to `WebSocketClient.lastDisconnectReason`. Falls back
    /// to `.connecting` / `.stalled` when the reason is nil. (§30/2)
    static func classify(isConnected: Bool,
                          isConnecting: Bool,
                          isAuthenticated: Bool,
                          reason: DisconnectReason?,
                          hasPaired: Bool) -> TopBarStatus {
        if isConnected { return .connected }
        if !hasPaired { return .unpaired }
        if let mapped = reason?.topBarStatus {
            return mapped
        }
        if isConnecting { return .connecting }
        return .stalled
    }
}

/// Voice-press readiness shown next to the connection dot. Answers the
/// question "if I press the volume button right now, will my voice land
/// in Codex?" — surfacing the three independent prerequisites that have
/// historically failed silently:
///   1. WebSocket authenticated (Mac is reachable + paired)
///   2. iOS mic permission granted (SFSpeech authorized)
///   3. Selected window's CLI is Codex (recent Mac routing — 0f578a1 —
///      sends Codex via pasteText; non-Codex falls back to keystroke
///      typing which doesn't land in Codex's textarea)
/// Pure classifier so it's unit-testable without a live client.
enum PTTReadiness: String, Equatable, CaseIterable {
    case ready          // green:  Codex selected + connected + mic OK
    case wrongCLI       // yellow: connected + mic OK but selected isn't Codex
    case offline        // gray:   not connected
    case micDenied      // red:    SFSpeech permission denied / restricted

    var symbol: String {
        switch self {
        case .ready:     return "mic.fill"
        case .wrongCLI:  return "mic"
        case .offline:   return "mic"
        case .micDenied: return "mic.slash.fill"
        }
    }

    var label: String {
        switch self {
        case .ready:     return "Ready for voice"
        case .wrongCLI:  return "Selected window isn't a voice CLI"
        case .offline:   return "Not connected"
        case .micDenied: return "Microphone permission denied"
        }
    }

    func color(colors: QuipColors) -> Color {
        switch self {
        case .ready:     return colors.statusConnected
        case .wrongCLI:  return colors.statusConnecting
        case .offline:   return .secondary.opacity(0.4)
        case .micDenied: return .red
        }
    }

    static func classify(isAuthenticated: Bool,
                          isAuthorized: Bool,
                          selectedCLI: CLIKind?) -> PTTReadiness {
        if !isAuthorized { return .micDenied }
        if !isAuthenticated { return .offline }
        // Voice is ready when the selected window is a paste-path AI CLI.
        // Both Codex and Grok route through the Mac's pasteText path (see
        // TextInjectionRoute.choose) and accept dictated prompts identically.
        // Grok was missed when its routing landed (420272e) — this enum stayed
        // Codex-only, so Grok panes wrongly read "isn't Codex". (GH I.)
        switch selectedCLI {
        case .codex, .grok: return .ready
        case .claude, .cursor, .shell, .none: return .wrongCLI
        }
    }

    /// Tiny inline tag shown next to the icon when the state isn't `.ready`.
    /// Returns nil when the icon alone (or the connection dot for `.offline`)
    /// already conveys the reason — keeps the row from getting noisy when
    /// nothing is wrong.
    func shortHint(selectedCLI: CLIKind?) -> String? {
        switch self {
        case .ready:     return nil
        case .wrongCLI:
            switch selectedCLI {
            case .claude:  return "claude"
            case .shell:   return "shell"
            case .cursor:  return "cursor"
            case .none:    return "?"
            // Defensive: classify() maps codex/grok → .ready, so neither
            // reaches a .wrongCLI badge. Kept exhaustive for the compiler.
            case .codex, .grok: return nil
            }
        case .offline:   return nil    // Top-bar status pill already covers it
        case .micDenied: return "no mic"
        }
    }
}

/// Friendly classification of round-trip text-land latency. Three buckets
/// matched to user perception, not engineering targets — at <250ms voice
/// transcripts feel instant, at 250–600ms there's a noticeable lag but
/// the loop still works, past 600ms users start retyping. The badge is
/// the at-a-glance answer to "is the link snappy right now?" — the
/// detail sheet is for when the user wants to dig.
enum LatencySummary: Equatable {
    case empty                  // No samples yet — first run or post-disconnect
    case snappy(avgMs: Int)     // < 250ms p50
    case ok(avgMs: Int)         // 250 – 600ms
    case slow(avgMs: Int)       // > 600ms

    /// Build from the last N samples (or all if fewer). Computes the median
    /// total RTT — median over mean so a single 5s outlier doesn't mask an
    /// otherwise-snappy distribution.
    static func from(samples: [WebSocketClient.LatencySample], window: Int = 20) -> LatencySummary {
        let recent = samples.suffix(window)
        guard !recent.isEmpty else { return .empty }
        let sorted = recent.map(\.totalRtt).sorted()
        let median = sorted[sorted.count / 2]
        if median < 250 { return .snappy(avgMs: median) }
        if median < 600 { return .ok(avgMs: median) }
        return .slow(avgMs: median)
    }

    var color: Color {
        switch self {
        case .empty:  return .secondary.opacity(0.5)
        case .snappy: return .green
        case .ok:     return .yellow
        case .slow:   return .red
        }
    }

    var label: String {
        switch self {
        case .empty:                return "—"
        case .snappy(let ms):       return "Snappy \(ms)ms"
        case .ok(let ms):           return "OK \(ms)ms"
        case .slow(let ms):         return "Slow \(ms)ms"
        }
    }

    /// Compact pill suitable for a Settings list row's accessory area.
    @ViewBuilder
    func badgeView() -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

struct MainiOSView: View {
    @Bindable var client: WebSocketClient
    /// Q-87: the Claude preview open full screen, if any.
    @State private var openClaudePreview: ClaudePreviewItem?
    @Bindable var manager: BackendConnectionManager
    var speech: SpeechService
    var bonjourBrowser: BonjourBrowser
    @Binding var windows: [WindowState]
    /// Q-62: true once this connection has delivered a layout. Until then an
    /// empty list means "not here yet", not "no windows", so the grid must
    /// not offer New Window (a duplicate spawn in waiting).
    @Binding var layoutReceived: Bool
    @Binding var selectedWindowId: String?
    @Binding var isRecording: Bool
    @Binding var terminalContentText: String?
    @Binding var terminalContentScreenshot: String?
    @Binding var terminalContentURLs: [String]?
    @Binding var terminalContentWindowId: String?
    @Binding var terminalContentUpdatedAt: Date?
    @Binding var terminalContentTextById: [String: String]
    @Binding var terminalContentScreenshotById: [String: String]
    @Binding var terminalContentURLsById: [String: [String]]
    @Binding var terminalContentUpdatedAtById: [String: Date]
    @Binding var terminalAutosuggestById: [String: TerminalAutosuggest]
    @Binding var showPINEntry: Bool
    @Binding var pinText: String
    var projectDirectories: [String]
    @Binding var iTermScanResults: [ITermWindowInfo]?
    /// Deadline for the iTerm scan. `iTermScanResults == nil` used to mean
    /// "scanning…" forever if the Mac never answered (old Mac build with no
    /// scan handler, or a socket that died one-sided). Now the wait has an end.
    @StateObject private var iTermScanRequest = PendingMacRequest(deadline: 10)
    var pushRegistration: PushRegistrationService
    var attentionCenter: WindowAttentionCenter
    @Binding var errorToast: String?
    var ttsOverlayTexts: [String: String]
    var monitorName: String
    var screenAspect: Double
    /// Every display on the Mac, primary first. Empty or single-element =>
    /// no screen chips (nothing to switch between).
    var displays: [DisplayState]
    /// width / height of all displays combined — the "All screens" canvas.
    var spanAspect: Double
    var spaces: [SpaceState]
    @Binding var selectedSpaceID: String?
    /// nil = show every screen on one merged canvas.
    @Binding var selectedDisplayID: String?
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
    /// Whether the desktop chips are showing in full. Collapsed by default and
    /// deliberately NOT persisted: it is a momentary "let me see my options"
    /// state, not a preference, so it costs no `PreferencesSnapshot` field and
    /// nothing to restore on a reinstall.
    @State private var spaceChipsExpanded = false
    /// Labs gate for the whole filter row (visibility chips + per-monitor
    /// chips). Off by default — see `LabsFlags.windowFilters`. Read here rather
    /// than at each chip so the row, the grid and the canvas can never disagree
    /// about whether filtering is in force: every filter goes through
    /// `effectiveSpaceID` / `pinnedDisplayID`, and both return "no filter" when
    /// this is off.
    @AppStorage(LabsFlags.windowFilters) private var labsWindowFilters = false
    @State private var hasAutoShownPermsForConnection = false

    @AppStorage("lastURL") private var urlText: String = ""
    @AppStorage("recentConnectionsData") private var recentConnectionsData: Data = Data()
    @AppStorage("ttsEnabled") private var ttsEnabled = false
    // Default covers the most common Claude Code interactions: one slash
    // command, the Y/N confirmations that Claude asks for, Esc to dismiss,
    // and Ctrl+C to abort. Everything else is opt-in from Settings.
    @AppStorage("enabledQuickButtons") private var enabledQuickButtonsRaw: String = "plan,yes,no,esc,ctrlC"
    // New ordered slot list — supersedes the CSV above. JSON-encoded
    // `[QuickSlot]`. Empty string triggers migration from the CSV on first
    // read (see `effectiveQuickSlots` in MainiOSView).
    @AppStorage("quickSlotsJSON") private var quickSlotsJSON: String = ""
    // User-defined custom buttons. JSON-encoded `[CustomButton]`. Defaults
    // to "[]". Slots reference these by UUID via `.custom(id)`.
    @AppStorage("customButtonsJSON") private var customButtonsJSON: String = "[]"
    // Legacy last-use log (prompt id → ISO-8601). Read once to seed
    // `promptUsageJSON`, then cleared; kept only for that migration.
    @AppStorage("promptUsageMRUJSON") private var promptUsageMRUJSON: String = "{}"
    // Per-device prompt usage (`PromptRanker.Store`): use counts, frecency and
    // per-agent frecency. Orders the picker and the broadcast sheet. Backed up
    // to the Mac in `PreferencesSnapshot` and merged on restore, never clobbered.
    @AppStorage("promptUsageJSON") private var promptUsageJSON: String = "{}"
    /// Prompts the user hid on this phone (VibeCut inherit, US-005). Shared with
    /// the settings editor via the same @AppStorage key; drives the picker filter.
    @AppStorage("hiddenPromptIDsJSON") private var hiddenPromptIDsJSON: String = "[]"
    @State private var showPromptsPickerSheet = false
    @State private var showSlashSearch = false
    /// The open Broadcast sheet, nil when closed. Carries the draft, the
    /// prompt it came from and the starting selection (US-107/108/111/114).
    @State private var broadcastRequest: BroadcastSheetRequest?
    /// The last broadcast's delivery, one line in the toast area until it is
    /// tapped or times out (US-111). A new broadcast replaces it.
    @State private var broadcastDelivery: BroadcastDelivery?
    /// The pending hide of the result line. Cancelled by every new hide, so
    /// a 4 s hide armed when a paste-route broadcast settled cannot cut short
    /// the 15 s a later attributed error gives the Retry tap.
    @State private var broadcastHideTask: Task<Void, Never>?
    /// The deadline that marks unanswered targets (US-111); a new broadcast
    /// cancels the old one.
    @State private var broadcastDeadlineTask: Task<Void, Never>?
    @State private var broadcastToastTask: Task<Void, Never>?
    /// Bumped to play the warning haptic when Broadcast cannot open.
    @State private var broadcastWarningTick = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Full-width Broadcast bar above the main row (US-109). Off hides it;
    /// Broadcast can still be a Quick Button.
    /// Owner: "it should be on the main keyboard, not another row, next to
    /// the microphone." The bar stays available but is off by default; the
    /// icon tile beside the mic is the default way in.
    @AppStorage("mainRow.broadcastBar") private var mainRowBroadcastBar: Bool = false
    @AppStorage("mainRow.broadcast") private var mainRowBroadcast: Bool = true
    /// Q-65: the main row's user-arranged order (hold a button, drag it).
    @AppStorage("mainRowOrderJSON") private var mainRowOrderJSON: String = ""
    @State private var mainReorder = RowReorderState()
    @State private var quickReorder = RowReorderState()
    /// Q-65: the slash pills' hold palette, presented from the reorder
    /// gesture (a context menu cannot share the long press with the drag).
    @State private var showSlashPalette = false
    /// Q-67: the keyboard button held still, whose menu (Edit, Color,
    /// Remove…) is showing.
    @State private var quickMenuSlot: QuickSlot?
    /// Q-67: the keyboard button open in the edit form.
    @State private var editingQuickSlot: QuickSlot?
    /// Q-67: the keyboard button open in the color sheet.
    @State private var coloringQuickSlot: QuickSlot?
    /// The prompt open in the editor from a prompt button's hold menu.
    @State private var editingQuickPrompt: PromptEntry?
    /// Mac's reply to that editor's save; the editor closes on success.
    @State private var quickPromptAck: PutPromptAckMessage?
    /// Q-51: the keyboard button whose "Send to…" window list is open.
    @State private var sendToSlot: QuickSlot?
    /// One neutral line under the top of the screen ("Sent to api", "Removed
    /// Y" with Undo); gone after 4 s (8 s with Undo) or a newer note.
    @State private var rowNote: RowNote?
    @State private var rowNoteTask: Task<Void, Never>?
    // Per-button toggles for the main control row (chevrons, spawn, arrange,
    // photo, keyboard, return). PTT mic and the row itself stay mandatory.
    // Default ON — existing users keep their current button set.
    @AppStorage("mainRow.cycleLeft") private var mainRowCycleLeft: Bool = true
    @AppStorage("mainRow.cycleRight") private var mainRowCycleRight: Bool = true
    @AppStorage("mainRow.spawn") private var mainRowSpawn: Bool = true
    @AppStorage("mainRow.arrange") private var mainRowArrange: Bool = true
    @AppStorage("mainRow.photo") private var mainRowPhoto: Bool = true
    @AppStorage("mainRow.prompts") private var mainRowPrompts: Bool = false
    /// One-shot flag — set after `mainRowPrompts` has been auto-flipped on
    /// because the user has at least one prompt in their library. Without
    /// the flag the auto-on would fight a user who turned it off in
    /// Settings (catalog refreshes every reconnect → re-flip → infinite
    /// fight). Once tripped, all subsequent toggle behaviour is manual.
    @AppStorage("mainRow.prompts.autoEnabledOnce") private var promptsAutoEnabledOnce: Bool = false
    @AppStorage("mainRow.keyboard") private var mainRowKeyboard: Bool = true
    @AppStorage("mainRow.return") private var mainRowReturn: Bool = true
    /// (wishlist §B16.) Mirrors the QuipApp-level pref so the Auto pill in
    /// the window picker can read + toggle it. Stays in sync via @AppStorage's
    /// shared UserDefaults backing — no manual fan-out needed.
    @AppStorage("followFrontmost") private var followFrontmost: Bool = true
    @State private var showSettings = false
    /// §26 — shake-to-diagnose sheet trigger. Set to true when the
    /// device shake gesture fires; the sheet reads from a snapshot
    /// captured at present time so values don't churn while the user
    /// is reading.
    @State private var showDiagnosticsSheet = false
    @State private var diagnosticsSnapshot: String = ""
    /// Multi-backend picker sheet trigger.
    @State private var showBackendPicker = false
    @State private var showQRScanner = false
    @State private var showSpawnPicker = false
    @AppStorage("spawnAgent") private var spawnAgentRaw: String = SpawnAgent.claude.rawValue
    /// Which tab the Spawn sheet is on. "new" shows project directories
    /// (classic path), "attach" shows the list of iTerm windows currently
    /// open on the Mac that Quip isn't already tracking.
    @State private var spawnSheetTab: SpawnSheetTab = .new
    /// iTerm session ids attached from this phone that the Mac's scan has not
    /// yet reported as tracked. Survives the sheet closing, so the row shows
    /// "Attached" on the next open without a manual rescan.
    @State private var recentlyAttachedSessionIds: Set<String> = []
    @State private var recentConnections: [SavedConnection] = []
    @State private var editingConnection: SavedConnection?
    @State private var renameText: String = ""
    @State private var showURLWarning = false
    @State private var pendingUnsafeURL: URL?
    @State private var testState: ConnectionTestState = .idle
    @State private var testResultAutoDismiss: Task<Void, Never>?
    /// Which layout the next tap on the arrange button will send. The icon
    /// shown on the button reflects this so the user can predict the outcome.
    /// Phone-only display layout for window rectangles. `""` = show whatever
    /// the auto-chooser picks (or Mac's frames if both this and per-window
    /// overrides are empty); `"horizontal"` = columns side-by-side on the
    /// phone; `"vertical"` = rows top-to-bottom. **Does not** touch the
    /// Mac's actual window positions — just reorganizes the preview here.
    /// Persisted across launches; @AppStorage so a returning user keeps
    /// their last mode without a flash of unstyled layout on cold launch.
    @AppStorage("phoneLayoutOverride") private var phoneLayoutOverrideRaw: String = ""
    /// True once the user has explicitly cycled the arrange button or
    /// dragged a window — auto-chooser stops firing on subsequent
    /// windows-list arrivals so we don't fight the user's choice.
    /// Realign button (US-002) clears this flag back to false.
    @AppStorage("phoneLayoutManualSticky") private var manualLayoutSticky: Bool = false
    /// Per-window manual position overrides written by drag-to-move (US-005).
    /// JSON-encoded `[String: WindowFrame]` keyed by `windowId`. Lookup wins
    /// over auto-arrange in `phoneLayoutFrame`. Pruned on every windows-list
    /// arrival so closed windows don't leak entries.
    @AppStorage("phoneFrameOverridesJSON") private var phoneFrameOverridesJSON: String = "{}"
    /// In-memory cache of decoded overrides — rebuilt from JSON on appear,
    /// written back to JSON on every mutation. Avoids a JSON round-trip per
    /// `phoneLayoutFrame` call inside the layout `ForEach`.
    @State private var phoneFrameOverrides: [String: WindowFrame] = [:]
    /// Persisted phone-side window ORDER. JSON `[String]` of windowIds written
    /// by drag-reorder. The layout renders `windows` sorted by this so a user's
    /// arrangement survives every Mac layout-update (each update replaces the
    /// `windows` binding wholesale). New windows append; closed ones prune.
    @AppStorage("phoneWindowOrderJSON") private var phoneWindowOrderJSON: String = "[]"
    /// In-memory decoded order — same JSON-cache pattern as phoneFrameOverrides.
    @State private var phoneWindowOrder: [String] = []
    /// Active drag state: which window is being dragged + accumulated
    /// translation. Nil when no drag is in flight.
    @State private var draggingWindowId: String? = nil
    @State private var dragTranslation: CGSize = .zero
    /// Last device-detected windows count + orientation snapshot used to
    /// short-circuit the chooser when nothing relevant changed.
    @State private var lastChooserCount: Int = -1

    /// Computed view of the persisted raw string. `""` ↔ nil so callers
    /// can keep working in the "no override" mental model without seeing
    /// the @AppStorage encoding artifact.
    private var phoneLayoutOverride: String? {
        phoneLayoutOverrideRaw.isEmpty ? nil : phoneLayoutOverrideRaw
    }

    /// `windows` reordered by the user's persisted phone order. Known ids come
    /// first in saved order; anything new (not yet in `phoneWindowOrder`) keeps
    /// its incoming position at the end. PURE — never mutates state — so it's
    /// safe to read from `body`. Reconciling the saved order to the live id set
    /// happens in `.onChange(of: windows)` via `reconcileWindowOrder`.
    private var displayWindows: [WindowState] {
        PhoneWindowOrder.display(windows, savedOrder: phoneWindowOrder)
    }
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

    // QA mode picker — set when user long-presses a window and taps
    // "Pair for QA" in the context menu. `qaPickerSourceWindow` holds the
    // long-pressed window's id (one half); the sheet picks the OTHER half.
    @State private var showQAPicker: Bool = false
    @State private var qaPickerSourceWindow: String? = nil

    /// The window whose color sheet is open, from "Color…" in the card's
    /// long-press menu.
    @State private var colorSheetWindowId: String? = nil
    /// Colors the user gave keyboard buttons (see `KeyColors`).
    @AppStorage(KeyColors.storageKey) private var quickSlotColorsJSON: String = "{}"
    /// Q-50: every pill gets an icon and color from its words; off is the
    /// plain row from before. Phone only, not in the Mac backup.
    @AppStorage(KeyPillSpec.autoStyleKey) private var autoKeyStyle: Bool = true

    /// What the phone typed on the Mac by accepting an autosuggestion, and the
    /// window it typed it on. While the compose field still matches `text`, the
    /// Mac's input line holds exactly this, so Send means "press Return" — see
    /// `InputLineSend`. Cleared on send, on edit (which also wipes the Mac's
    /// line), and on switching windows, because an echo is only true of the
    /// window it came from.
    @State private var lineEcho: (windowId: String, text: String)? = nil
    @FocusState private var textInputFocused: Bool

    // `body` used to be one ~535-line chained expression and once failed
    // with "unable to type-check this expression in reasonable time" on an
    // unrelated one-line edit (Q-26). It is now split into stages, each of
    // which type-checks on its own. Modifier order is unchanged: the stages
    // apply them in exactly the sequence the single chain did.
    var body: some View {
        contentWithSheets
    }

    /// The view tree itself — QA pair layout, or status bar + content + controls.
    private var rootLayers: some View {
        ZStack {
            colors.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // QA mode replaces the status bar + grid + terminal +
                // controls with a side-by-side pair view. The bottomBar
                // (settings / connection menu) stays visible so the user
                // always has an escape hatch even if the header chip's
                // exit button is somehow obscured. (Task 16.)
                if let pair = manager.active.qaPair,
                   let target = windows.first(where: { $0.id == pair.targetId }),
                   let terminal = windows.first(where: { $0.id == pair.terminalId }) {
                    QAPairLayoutView(
                        target: target,
                        terminal: terminal,
                        selectedWindowId: $selectedWindowId,
                        contentTextById: $terminalContentTextById,
                        contentScreenshotById: $terminalContentScreenshotById,
                        contentURLsById: $terminalContentURLsById,
                        backendId: manager.activeBackendID,
                        onRefresh: { requestActiveContent() },
                        onSendText: { text in
                            client.send(SendTextMessage(windowId: selectedWindowId ?? "",
                                                        text: text,
                                                        pressReturn: true))
                        },
                        onExit: {
                            if let pair = manager.active.qaPair {
                                ContentMapMutations.purgePairContent(
                                    pair: (pair.targetId, pair.terminalId),
                                    from: &terminalContentTextById,
                                    &terminalContentScreenshotById,
                                    &terminalContentURLsById
                                )
                            }
                            manager.active.updateQAPair(nil)
                            client.clearQAPair()
                        },
                        onRePair: {
                            qaPickerSourceWindow = pair.targetId
                            showQAPicker = true
                        }
                    )
                } else {
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
                }

                bottomBar
                    .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// Recording backdrop, TTS banner, volume-button sink and the error toast.
    private var contentWithOverlays: some View {
        rootLayers
        .overlay { recordingOverlay }
        .overlay { speakingOverlay }
        .allowsHitTesting(true)
        .overlay { HiddenVolumeView().frame(width: 1, height: 1) }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                if let toast = errorToast {
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.85))
                        .clipShape(Capsule())
                        .transition(toastTransition)
                        .animation(.easeInOut(duration: 0.3), value: errorToast)
                }
                broadcastResultLine
                rowNoteLine
            }
            .padding(.top, 50)
            .animation(.easeInOut(duration: 0.3), value: broadcastDelivery?.startedAt)
            .animation(.easeInOut(duration: 0.3), value: rowNote?.id)
        }
        .sensoryFeedback(.warning, trigger: broadcastWarningTick)
        .environment(\.quipColors, colors)
    }

    @ViewBuilder
    private var recordingOverlay: some View {
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

    @ViewBuilder
    private var speakingOverlay: some View {
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

    /// Lifecycle wiring — onAppear / onChange / onReceive.
    private var contentWithLifecycle: some View {
        contentWithOverlays
        .onAppear {
            updateOrientation()
            // One-shot first-launch seed for the slot row + custom-button
            // table. Two paths:
            //   1) Truly-fresh install — both `quickSlotsJSON` empty AND
            //      `customButtonsJSON` is the empty-array default `"[]"`.
            //      Seed `defaultSlots(demoCustomID:)` + `defaultDemo()` so
            //      the row visibly demonstrates both built-ins AND a
            //      custom button the moment the app connects (no Settings
            //      drill-down needed, makes simulator QA viable).
            //   2) Upgrader from pre-§43 CSV — `quickSlotsJSON` empty but
            //      `customButtonsJSON` already has user data (or the CSV
            //      itself isn't the default value). Run the existing
            //      CSV→JSON migration so the user's curated row carries
            //      forward unchanged.
            if quickSlotsJSON.isEmpty {
                let isTrulyFresh =
                    customButtonsJSON == "[]" &&
                    enabledQuickButtonsRaw == "plan,yes,no,esc,ctrlC"
                if isTrulyFresh {
                    let demo = CustomButtonStore.defaultDemo()
                    customButtonsJSON = CustomButtonStore.encode([demo])
                    let seeded = QuickSlotStore.defaultSlots(demoCustomID: demo.id)
                    quickSlotsJSON = QuickSlotStore.encode(seeded)
                } else {
                    let migrated = QuickSlotStore.migrate(fromCSV: enabledQuickButtonsRaw)
                    quickSlotsJSON = QuickSlotStore.encode(migrated)
                }
            }
            // Restore persisted phone-side window overrides so a returning
            // user sees their drag layout before the first windows-list
            // arrives. No-op on first launch (empty JSON → empty dict).
            loadOverrides()
            // Restore the persisted drag-reorder sequence too, so a returning
            // user's order is in place before the first windows-list arrives.
            loadWindowOrder()
            // Initial chooser pass for the case where windows already
            // populated before this view appeared (rare but possible on
            // reconnect). Real subsequent fires happen via .onChange below.
            if !windows.isEmpty {
                pruneOverrides(activeWindowIds: Set(windows.map(\.id)))
                reconcileWindowOrder(activeWindows: windows)
                runAutoChooser(count: windows.count)
            }
        }
        .onChange(of: windows) { _, newValue in
            // FR-2 + FR-8: every windows-list change re-fires the chooser
            // (skipped when manualLayoutSticky is set) and prunes stale
            // override entries for closed windows.
            pruneOverrides(activeWindowIds: Set(newValue.map(\.id)))
            // Keep the drag-reorder sequence in step: append new windows,
            // drop closed ones, so displayWindows stays well-defined.
            reconcileWindowOrder(activeWindows: newValue)
            runAutoChooser(count: newValue.count)
        }
        .onAppear {
            // Companion onAppear for the rest of the legacy hookup below.
            // Register image upload result callbacks. These are idempotent
            // reassignments so re-firing onAppear is harmless.
            manager.onImageUploadAck = { [weak pendingImage] session, _ in
                guard session.backendID == manager.activeBackendID else { return }
                DispatchQueue.main.async {
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)
                    pendingImage?.markSentAndClear()
                }
            }
            manager.onImageUploadError = { [weak pendingImage] session, reason in
                guard session.backendID == manager.activeBackendID else { return }
                DispatchQueue.main.async { pendingImage?.markError(reason) }
            }
            manager.onSendTextAck = { session, messageID in
                guard session.backendID == manager.activeBackendID else { return }
                Task { @MainActor in confirmBroadcastTarget(messageID) }
            }
            manager.onSendTextError = { session, messageID in
                guard session.backendID == manager.activeBackendID else { return }
                Task { @MainActor in failBroadcastTarget(messageID) }
            }
        }
        .onChange(of: client.isConnected) { _, connected in
            withAnimation(.easeInOut(duration: 0.5)) {
                if !connected {
                    windows = []
                    layoutReceived = false
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
        .onReceive(NotificationCenter.default.publisher(for: .quipApplyPairing)) { note in
            // Triggered by the `quip://pair` deep link (AirDrop/Messages/Mail).
            // The App-scene `onOpenURL` decodes the payload and posts it here so
            // pairing runs through the SAME `applyPairingPayload` the in-app QR
            // scanner uses — `doConnect()` and `urlText` live on this view.
            guard let payload = note.object as? PairingPayload else { return }
            applyPairingPayload(payload)
        }
        .onReceive(NotificationCenter.default.publisher(for: .quipOpenBroadcast)) { note in
            // The Prompts hub's "Broadcast…" (US-108) and quip://broadcast (US-114).
            guard let link = note.object as? BroadcastLink.Request else { return }
            openBroadcast(link)
        }
        .onChange(of: client.isAuthenticated) { _, authenticated in
            if authenticated { PushAnswerQueue.shared.flush() }
            withAnimation(.easeInOut(duration: 0.5)) {
                if !authenticated {
                    windows = []
                    layoutReceived = false
                    selectedWindowId = nil
                }
                updateOrientation()
            }
        }
        // §A1: discoverability — first time the Mac broadcasts a non-empty
        // prompt catalog, auto-enable the main-row Prompts button so users
        // notice it exists. One-shot via `promptsAutoEnabledOnce` so a user
        // who turns it off in Settings doesn't see it pop back on every
        // reconnect.
        .onChange(of: client.promptLibrary.count) { _, count in
            // Prune hidden ids that no longer exist in the catalog (e.g. a prompt
            // dropped by a later VibeCut sync) so the set can't grow unbounded and
            // a re-created prompt can't be silently re-hidden.
            let present = Set(client.promptLibrary.map(\.id))
            if let pruned = PromptHideState.pruned(hiddenJSON: hiddenPromptIDsJSON, presentIDs: present) {
                hiddenPromptIDsJSON = pruned
            }
            guard count > 0, !promptsAutoEnabledOnce else { return }
            promptsAutoEnabledOnce = true
            mainRowPrompts = true
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
            // An echo is only true of the window it was typed on. Drop it AND
            // the field it is mirroring, so the next window's Send never
            // submits a line that belongs to the last one.
            if lineEcho != nil {
                if textInputValue == lineEcho?.text { textInputValue = "" }
                lineEcho = nil
            }
            // Auto-fetch terminal output for the inline view in portrait.
            if isPortrait, newId != nil { requestActiveContent() }
        }
    }

    /// Sheets, covers, confirmation dialogs and alerts.
    private var contentWithSheets: some View {
        contentWithLifecycle
        .sheet(isPresented: $showQRScanner) {
            QRScannerView { code in
                showQRScanner = false
                // Detect the §50 quip://pair?... shape — extract URL + PIN,
                // pre-stage the PIN in Keychain under the new backend's
                // synthetic id, then connect. Falls back to treating the
                // scan result as a plain ws(s) URL for backwards
                // compatibility with the original "raw URL in QR" flow.
                if let payload = PairingPayload.decode(code) {
                    applyPairingPayload(payload)
                } else {
                    urlText = code
                    doConnect()
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(
                enabledQuickButtonsRaw: $enabledQuickButtonsRaw,
                client: client,
                pushRegistration: pushRegistration,
                macPermissions: macPermissions,
                windowIdProvider: { selectedWindowId },
                promptContextProvider: { selectedPromptContext },
                projectProvider: { selectedProject },
                windowsProvider: { windows }
            )
        }
        .sheet(isPresented: $showPromptsPickerSheet) {
            // The one Prompts hub (Q-42): the same screen as Settings →
            // Prompts, so paste, send, edit, hide and delete all live in one
            // place. Firing goes through `firePromptSlot` so usage is counted.
            NavigationStack {
                PromptLibrarySheet(
                    client: client,
                    windowIdProvider: { selectedWindowId },
                    promptContextProvider: { selectedPromptContext },
                    projectProvider: { selectedProject },
                    windowsProvider: { windows },
                    onPick: { entry, pressReturn in
                        firePromptSlot(promptID: entry.id, pressReturn: pressReturn)
                        showPromptsPickerSheet = false
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSlashSearch) {
            // US-105 — "Search…" in the long-press slash palette.
            SlashSearchSheet(
                members: allSlashMembers(),
                onPick: { member in
                    switch member {
                    case .builtin(let b): fireQuickButton(b)
                    case .custom(let c): fireCustomButton(c)
                    }
                },
                isInRow: { effectiveQuickSlots.contains($0.slot) },
                sendAction: { QuickSend.action(for: $0.slot, defs: customButtonDefs) },
                targets: { SendToTargets.targets(from: windows, selectedID: selectedWindowId) },
                onSendTo: { member, windowID, action in sendQuick(action, slot: member.slot, to: windowID) },
                onTogglePin: { toggleQuickSlotPin($0.slot) },
                onEdit: { member in
                    // The search sheet is still closing; one sheet at a time.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editingQuickSlot = member.slot }
                }
            )
        }
        .sheet(item: $broadcastRequest) { request in
            BroadcastPromptSheet(
                windows: windows,
                library: client.promptLibrary,
                isConnected: client.isConnected,
                request: request,
                onSend: queueBroadcast
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showBackendPicker) {
            BackendPickerSheet(
                manager: manager,
                isActiveConnected: client.isConnected,
                isPresented: $showBackendPicker
            ) {
                // "Add backend" tapped: disconnect to surface the URL entry
                // so the user can paste/scan/Bonjour-pick a new daemon. The
                // existing connect path will append the new entry to
                // `paired` via `ensureImplicitDefault`.
                client.disconnect()
            }
        }
        .sheet(isPresented: $showDiagnosticsSheet) {
            DiagnosticsSheet(
                snapshot: diagnosticsSnapshot,
                canRequestMacBundle: client.isAuthenticated,
                onRequestMacBundle: {
                    client.send(RequestDiagnosticsMessage())
                }
            )
        }
        // Task 16 — QA-mode pair picker. Triggered by long-press → "Pair
        // for QA" in WindowRectangle's context menu, OR by the re-pair
        // button in the QAPairLayoutView header chip. The long-pressed
        // window IS one half; the sheet picks the OTHER half. Mode is
        // derived from the source window's classification — long-pressed
        // a Simulator → pick a terminal; long-pressed a terminal → pick
        // a Simulator.
        .sheet(isPresented: Binding(
            get: { colorSheetWindowId != nil },
            set: { if !$0 { colorSheetWindowId = nil } }
        )) {
            if let id = colorSheetWindowId,
               let window = windows.first(where: { $0.id == id }) {
                ColorChoiceSheet(
                    title: window.folder?.isEmpty == false ? window.folder! : window.name,
                    current: window.color
                ) { hex in
                    client.send(SetColorMessage(windowId: id, color: hex))
                }
            }
        }
        // Q-67: edit or color a keyboard button from its hold menu.
        .sheet(item: $editingQuickSlot) { slot in
            if let initial = QuickButtonEdit.editable(slot, defs: customButtonDefs) {
                CustomButtonForm(initial: initial,
                                 tint: KeyColors.decode(quickSlotColorsJSON)[slot.id],
                                 onSave: { edited in
                                     // Only the color changed: a built-in stays
                                     // a built-in instead of becoming a copy.
                                     if edited != initial { saveQuickEdit(edited, over: slot) }
                                 },
                                 // Runs before onSave, so a built-in's new color
                                 // moves with it if it becomes a copy.
                                 onColor: { hex in
                                     let colors = KeyColors.decode(quickSlotColorsJSON)
                                     quickSlotColorsJSON = KeyColors.encode(KeyColors.setting(hex, for: slot.id, in: colors))
                                 })
            }
        }
        // A prompt button edits the prompt itself, the same editor as the
        // Prompts hub; the save goes to the Mac, which owns the library.
        .sheet(item: $editingQuickPrompt) { entry in
            PromptEditorSheet(initial: entry, currentProject: selectedProject, latestAck: quickPromptAck) { entry, messageId in
                guard client.isConnected && client.isAuthenticated else { return false }
                return client.send(PutPromptMessage(
                    id: entry.id, label: entry.label, body: entry.body, messageId: messageId,
                    tags: entry.tags, targetAgent: entry.targetAgent, description: entry.description
                ))
            }
            .onAppear { client.onPutPromptAck = { quickPromptAck = $0 } }
            .onDisappear { client.onPutPromptAck = nil }
        }
        .sheet(item: $sendToSlot) { slot in
            if let action = QuickSend.action(for: slot, defs: customButtonDefs) {
                SendToWindowSheet(title: quickSlotTitle(slot), action: action,
                                  targets: SendToTargets.targets(from: windows, selectedID: selectedWindowId)) { windowID, action in
                    sendQuick(action, slot: slot, to: windowID)
                }
            }
        }
        .sheet(item: $coloringQuickSlot) { slot in
            let colors = KeyColors.decode(quickSlotColorsJSON)
            ColorChoiceSheet(title: quickSlotTitle(slot), current: colors[slot.id],
                             resetLabel: quickSlotColorResetLabel(slot)) { hex in
                quickSlotColorsJSON = KeyColors.encode(KeyColors.setting(hex, for: slot.id, in: colors))
            }
        }
        .sheet(isPresented: $showQAPicker) {
            if let sourceId = qaPickerSourceWindow,
               let source = windows.first(where: { $0.id == sourceId }) {
                let mode: QAPairPickerSheet.Mode = source.isTarget ? .terminal : .target
                QAPairPickerSheet(
                    mode: mode,
                    windows: windows,
                    onSelect: { other in
                        let pair: QAPair
                        if source.isTarget {
                            pair = QAPair(targetId: source.id, terminalId: other.id)
                        } else {
                            pair = QAPair(targetId: other.id, terminalId: source.id)
                        }
                        manager.active.updateQAPair(pair)
                        client.setQAPair(targetId: pair.targetId, terminalId: pair.terminalId)
                        showQAPicker = false
                        qaPickerSourceWindow = nil
                    },
                    onCancel: {
                        showQAPicker = false
                        qaPickerSourceWindow = nil
                    }
                )
            }
        }
        .background(
            // §26 — invisible shake detector mounted as a 0×0 background
            // view so it sits in the responder chain without taking
            // layout space. On shake, snapshot iPhone state into a
            // monospaced text block + present the diagnostics sheet.
            ShakeDetector {
                diagnosticsSnapshot = buildDiagnosticsSnapshot()
                showDiagnosticsSheet = true
            }
            .frame(width: 0, height: 0)
        )
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
            .onChange(of: iTermScanResults) { _, results in
                // The Mac answered (via manager.onITermWindowList) — the wait is
                // over. This is the only thing that can retire the scan short of
                // its deadline.
                if let results {
                    iTermScanRequest.resolve(.succeeded)
                    recentlyAttachedSessionIds = AttachListState.pruned(
                        recentlyAttachedSessionIds, afterScan: results)
                }
            }
            .onChange(of: showSpawnPicker) { _, isShowing in
                // Reset tab + scan state whenever the sheet closes so the
                // next open starts from a clean slate — including cancelling any
                // live deadline, so a dismissed sheet can't fire into a reopened one.
                if !isShowing {
                    spawnSheetTab = .new
                    iTermScanResults = nil
                    iTermScanRequest.reset()
                }
            }
        }
        .alert("Unrecognized Server", isPresented: $showURLWarning) {
            Button("Connect Anyway", role: .destructive) {
                if let url = pendingUnsafeURL {
                    connectToBackendURL(url)
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
        VStack(spacing: 0) {
            Picker("Agent", selection: $spawnAgentRaw) {
                ForEach(SpawnAgent.allCases.filter { $0 != .cursor }, id: \.self) { agent in
                    Text(agent.displayName).tag(agent.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .accessibilityLabel("New session agent")
            .onAppear {
                if spawnAgentRaw == SpawnAgent.cursor.rawValue {
                    spawnAgentRaw = SpawnAgent.claude.rawValue
                }
            }

            if projectDirectories.isEmpty {
                ContentUnavailableView(
                    "No Project Directories",
                    systemImage: "folder.badge.plus",
                    description: Text("Add directories in Quip Mac Settings → Directories tab")
                )
            } else {
                List(projectDirectories, id: \.self) { dir in
                    Button {
                        client.send(SpawnWindowMessage(directory: dir, agent: selectedSpawnAgent))
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
            } else if let failure = iTermScanRequest.failureMessage {
                // The scan was armed with a deadline and blew through it. Say so,
                // and give the user the one thing they can do about it.
                ContentUnavailableView {
                    Label("Scan failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try again") { requestITermScan() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                // nil + in-flight = scanning. Bounded by iTermScanRequest's deadline.
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
        // The Mac's scan can lag behind an attach by several seconds, so a row
        // tapped from this phone counts as attached until a scan agrees.
        let attached = AttachListState.isAttached(info, recent: recentlyAttachedSessionIds)
        let dimmed = attached || info.isMiniaturized
        Button {
            guard !attached else { return }
            recentlyAttachedSessionIds.insert(info.sessionId)
            client.send(AttachITermWindowMessage(
                windowNumber: info.windowNumber,
                sessionId: info.sessionId
            ))
            showSpawnPicker = false
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(attached ? Color.secondary : Color.green)
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
                if attached {
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
            .opacity(dimmed && !attached ? 0.6 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(attached)
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
    /// re-renders with the list, and `.onChange` resolves the request.
    ///
    /// The scan is armed with a deadline: if the Mac never answers, the spinner
    /// becomes an error with a retry rather than spinning until the user gives
    /// up and force-quits.
    private func requestITermScan() {
        iTermScanResults = nil
        iTermScanRequest.start()
        guard client.send(ScanITermWindowsMessage()) else {
            // The frame never left the phone — don't arm a wait for a reply
            // that provably cannot come.
            iTermScanRequest.resolve(.failed(cause: "Couldn't reach the Mac",
                                             nextStep: "Reconnect, then tap rescan"))
            return
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
                    ForEach(newDiscoveredHosts) { host in
                        Button {
                            if let url = host.wsURL {
                                // A Mac that already has a row reconnects that
                                // row on this address instead of becoming a
                                // second row (US-012).
                                if !manager.reconnectToDiscoveredHost(deviceID: host.deviceID, url: url) {
                                    connectToBackendURL(url)
                                }
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
                // Fold any discovered host that belongs to a Mac we already know
                // (TXT deviceID match) into that paired row's URLs, instead of
                // listing it as a new backend — the anti-flap contract. Unknown
                // Macs fall through to `newDiscoveredHosts` and stay listed.
                .onChange(of: bonjourBrowser.discoveredHosts) { _, hosts in
                    for host in hosts {
                        if let url = host.wsURL?.absoluteString {
                            manager.ingestDiscoveredHost(deviceID: host.deviceID, url: url)
                        }
                    }
                }
            }

            // No Macs discovered after the grace window — most often iOS
            // Local Network permission is off (Bonjour then silently returns
            // nothing). Surface a tappable hint to Settings rather than
            // leaving the user staring at an empty list. Heuristic, not a
            // hard permission read (iOS exposes none).
            if bonjourBrowser.discoveredHosts.isEmpty, bonjourBrowser.graceElapsed,
               let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Link(destination: settingsURL) {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 14))
                            .foregroundStyle(colors.textTertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("No Macs found on Wi-Fi")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(colors.textTertiary)
                            Text("If yours is on this network, tap to check Local Network access")
                                .font(.system(size: 10))
                                .foregroundStyle(colors.textFaint)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 10))
                            .foregroundStyle(colors.textFaint)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("No Macs found on Wi-Fi. If yours is on this network, tap to check Local Network access in Settings.")
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
        // §K — top-bar 4-state pill. Binary green/yellow missed "stalled
        // mid-handshake / NAT-idle drop / auth-failed / not-paired".
        // Pure classifier `TopBarStatus.classify(...)` returns the right
        // color + label; pinned by unit tests.
        let topStatus = TopBarStatus.classify(
            isConnected: client.isConnected,
            isConnecting: client.isConnecting,
            isAuthenticated: client.isAuthenticated,
            reason: client.lastDisconnectReason,
            hasPaired: !manager.paired.isEmpty
        )
        return HStack(spacing: 4) {
            // Tap the dot+label to open the multi-backend picker. Hidden when
            // there's no paired entry yet (first launch) so the affordance
            // only shows up once it's actionable.
            Button {
                if !manager.paired.isEmpty {
                    showBackendPicker = true
                }
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(topStatus.dot(colors: colors))
                        .frame(width: 6, height: 6)
                    Text(topStatus.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(colors.textSecondary)
                    if manager.paired.count > 1 {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(colors.textTertiary)
                        Text("\(manager.paired.count) paired")
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(colors.textTertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connection: \(topStatus.label)")
            .accessibilityHint(manager.paired.isEmpty ? "No backends paired yet" : "Open backend picker")
            // PTT readiness — green only when a volume-button press would
            // actually reach a paste-path voice CLI (Codex or Grok). Yellow
            // when connected but selected window is Claude / cursor / shell.
            // Red when mic permission is denied.
            // The optional shortHint surfaces *which* CLI is foregrounded
            // (or "no mic") so the user knows why it's not green without
            // having to dig into Settings.
            let pttSelectedCLI = windows.first(where: { $0.id == selectedWindowId })?.cliKind
            let ptt = PTTReadiness.classify(
                isAuthenticated: client.isAuthenticated,
                isAuthorized: speech.isAuthorized,
                selectedCLI: pttSelectedCLI
            )
            HStack(spacing: 2) {
                Image(systemName: ptt.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(ptt.color(colors: colors))
                if let hint = ptt.shortHint(selectedCLI: pttSelectedCLI) {
                    Text(hint)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(ptt.color(colors: colors))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Push-to-talk: \(ptt.label)")
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
            .accessibilityLabel({
                if let perms = macPermissions,
                   !(perms.accessibility && perms.appleEvents && perms.screenRecording) {
                    return "Settings, Mac permission needed"
                }
                return "Settings"
            }())
            .accessibilityAddTraits(.isButton)
            // One-tap recovery: visible only while disconnected so the user
            // can break the "stuck on Connecting…" state without digging
            // through settings. Disconnects + reconnects to the active URL.
            if !client.isConnected, let url = client.serverURL {
                Button {
                    client.disconnect()
                    client.connect(to: url)
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textTertiary)
                        .frame(width: 20, height: 20)
                }
                .accessibilityLabel("Reset connection")
                .accessibilityHint("Disconnect and reconnect to the Mac")
                .accessibilityAddTraits(.isButton)
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
            .accessibilityLabel("Disconnect")
            .accessibilityHint("Close the connection to the Mac")
            .accessibilityAddTraits(.isButton)
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
                .accessibilityLabel("Cancel authentication")
                .accessibilityHint("Disconnect from the Mac")
                .accessibilityAddTraits(.isButton)
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
        // Portrait button widths shrunk so the full mainRow cluster
        // (cycleLeft+cycleRight + spawn+arrange + mic + photo+prompts+keyboard+return)
        // fits on a single 430pt-wide iPhone 17 Pro Max line. Old 56pt buttons
        // summed to ~460pt with all toggles enabled, blowing the parent VStack
        // wider than the screen and clipping the window-cards row + status header.
        // 48pt × 6 + nav/ptt/aux + Spacers stays under 430.
        let btnH: CGFloat = isPortrait ? 56 : 40
        let btnW: CGFloat = isPortrait ? 48 : 44
        // The mic gives up 8 pt when the broadcast tile sits beside it, so the
        // row still fits the 440 pt screen with every button on.
        let pttW: CGFloat = isPortrait ? (mainRowBroadcast ? 56 : 64) : 56
        let navW: CGFloat = isPortrait ? 24 : 22
        let navH: CGFloat = isPortrait ? 36 : 28
        let auxW: CGFloat = isPortrait ? 36 : 32
        let auxH: CGFloat = isPortrait ? 56 : 40

        return VStack(spacing: isPortrait ? 8 : 4) {
            // Pending image thumbnail — only takes space when an image is attached.
            // §L — host wires the recovery affordance so the user has an
            // actionable next step when the watchdog trips. Each
            // category routes somewhere useful: timeout → reset socket
            // (forces reconnect via existing client.disconnect/connect
            // dance); window-closed → re-open the picker; data-invalid →
            // clear the pending image so the user can try another;
            // disk-write → just clear so they can retry. The host
            // controls these so the strip stays a dumb renderer.
            PendingImagePreviewStrip(state: pendingImage, onRecoveryAction: { category in
                switch category {
                case .timeout:
                    if let url = client.serverURL {
                        client.disconnect()
                        client.connect(to: url)
                    }
                    pendingImage.clear()
                case .unknownWindow:
                    pendingImage.clear()
                    showBackendPicker = true
                case .invalidData, .macDiskWrite, .tooLarge, .other:
                    pendingImage.clear()
                }
            })

            // GH H: PTT health banner — single-line capsule that surfaces
            // path-degraded states near the mic button instead of leaving
            // them buried in Settings. Hidden when nothing notable;
            // collapses cleanly so the row layout doesn't shift.
            if let info = pttHealthBanner {
                HStack(spacing: 6) {
                    Image(systemName: info.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(info.tint)
                    Text(info.message)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(info.tint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(info.tint.opacity(0.12))
                .clipShape(Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Voice input status: \(info.message)")
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if mainRowBroadcastBar {
                broadcastPromptButton
            }

            // Control buttons — every button is a row item the user can hold
            // and drag to a new slot (Q-65). The mic is the fixed middle:
            // items before it form the left group, items after it the right
            // group, and the flexible spacers keep the mic centred whatever
            // the user shows or moves. Dragging past the mic changes sides.
            let visibleOrder = mainRowOrder.filter { mainRowItemVisible($0) }
            let micAt = visibleOrder.firstIndex(of: MainRowOrder.mic) ?? visibleOrder.count
            let leftIDs = Array(visibleOrder[..<micAt])
            let rightIDs = micAt < visibleOrder.count ? Array(visibleOrder[(micAt + 1)...]) : []
            // The row measures itself and shrinks its tiles in proportion
            // when they would not fit (Q-65), instead of clipping the edges.
            GeometryReader { rowGeo in
            let sizes = MainRowSizes(navW: navW, navH: navH, btnW: btnW, btnH: btnH, auxW: auxW, auxH: auxH, pttW: pttW)
                .fitted(to: rowGeo.size.width, visible: visibleOrder)
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(leftIDs, id: \.self) { id in
                        mainRowItem(id, sizes: sizes)
                            .rowReorderItem(id, state: mainReorder, space: "mainRow", order: visibleOrder,
                                            tap: mainRowTapAction(id), hold: mainRowHoldAction(id),
                                            onMove: moveMainRowItem)
                    }
                }

                // Big flexible spacer pinning mic to geometric center.
                Spacer(minLength: 8)

                micButton(sizes: sizes)
                    .rowFrame(MainRowOrder.mic, space: "mainRow", state: mainReorder)

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    ForEach(rightIDs, id: \.self) { id in
                        mainRowItem(id, sizes: sizes)
                            .rowReorderItem(id, state: mainReorder, space: "mainRow", order: visibleOrder,
                                            tap: mainRowTapAction(id), hold: mainRowHoldAction(id),
                                            onMove: moveMainRowItem)
                    }
                }

                // In landscape, fold the quick-button row INTO this main row
                // — saves a whole row of vertical space and keeps everything
                // reachable in one thumb-sweep. Portrait keeps the 2-row
                // layout below because there isn't width to spare.
                if !isPortrait {
                    let slots = effectiveQuickSlots
                    if !slots.isEmpty {
                        Spacer().frame(width: 8)
                        slotRowView(slots, space: "mainRow")
                    }
                }
            }
            .coordinateSpace(name: "mainRow")
            .confirmationDialog("Slash commands", isPresented: $showSlashPalette, titleVisibility: .visible) {
                let members = allSlashMembers()
                if SlashSearchSheet.offersSearch(memberCount: members.count) {
                    Button("Search…") { showSlashSearch = true }
                }
                ForEach(members) { member in
                    Button(member.displayName) {
                        switch member {
                        case .builtin(let b): fireQuickButton(b)
                        case .custom(let c): fireCustomButton(c)
                        }
                    }
                }
            }
            // Q-67: hold a keyboard button still for its menu.
            .confirmationDialog(quickMenuSlot.map(quickSlotTitle) ?? "", isPresented: Binding(
                get: { quickMenuSlot != nil },
                set: { if !$0 { quickMenuSlot = nil } }
            ), titleVisibility: .visible, presenting: quickMenuSlot) { slot in
                quickMenuActions(slot)
            }
            }
            .frame(height: btnH)

            // Portrait-only secondary command-shortcut row. Slots render in
            // user-controlled order — they place `.spacer` slots themselves
            // via the editor (Apple-toolbar-style customization).
            //
            // Wrapped in a horizontal `ScrollView` so the row stays a single
            // line no matter how many slots the user has placed — adding
            // chips beyond what fits on-screen scrolls horizontally instead
            // of pushing the parent VStack wider and clipping the window
            // cards / "Connected" header above it. Indicators hidden so the
            // chrome stays clean; users discover scroll via the natural
            // truncation cue at the right edge.
            if isPortrait {
                let slots = effectiveQuickSlots
                if !slots.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 3) {
                            slotRowView(slots, space: "quickRow")
                        }
                        .padding(.horizontal, 6)
                        .coordinateSpace(name: "quickRow")
                    }
                    // Pin ScrollView to parent's available width. Without
                    // this, SwiftUI can propagate the inner HStack's
                    // intrinsic content size up the layout tree, which on
                    // a wide-enough chip row pushes the parent VStack out
                    // beyond the screen and clips the window-cards row +
                    // status header above. The frame caps width at parent
                    // so overflow stays inside ScrollView (where it
                    // scrolls) rather than leaking up.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, isPortrait ? 8 : 4)
    }

    // MARK: - Main row items (Q-65)

    private var mainRowOrder: [String] { MainRowOrder.decode(mainRowOrderJSON) }

    private func mainRowItemVisible(_ id: String) -> Bool {
        switch id {
        case MainRowOrder.cycleLeft: return mainRowCycleLeft && !isQAModeActive
        case MainRowOrder.cycleRight: return mainRowCycleRight && !isQAModeActive
        case MainRowOrder.spawn: return mainRowSpawn && !isQAModeActive
        case MainRowOrder.arrange: return mainRowArrange && !isQAModeActive
        case MainRowOrder.mic: return true
        case MainRowOrder.broadcast: return mainRowBroadcast && !isQAModeActive
        case MainRowOrder.photo: return mainRowPhoto && !isQAModeActive
        case MainRowOrder.prompts: return mainRowPrompts && !isQAModeActive
        case MainRowOrder.keyboard: return mainRowKeyboard
        case MainRowOrder.return: return mainRowReturn
        default: return false
        }
    }

    /// Move `id` to `index` among the VISIBLE items and persist the full
    /// order: hidden buttons keep their relative places and follow the
    /// visible ones, so toggling one back on does not scramble the row.
    private func moveMainRowItem(_ id: String, to index: Int) {
        let full = mainRowOrder
        let visible = full.filter { mainRowItemVisible($0) }
        let movedVisible = RowReorderMath.move(visible, id: id, to: index)
        let hidden = full.filter { !mainRowItemVisible($0) }
        mainRowOrderJSON = MainRowOrder.encode(movedVisible + hidden)
    }

    /// What a tap does on a main-row button, nil while it is disabled. The
    /// Button inside each item calls the same closure, for VoiceOver.
    private func mainRowTapAction(_ id: String) -> (() -> Void)? {
        switch id {
        case MainRowOrder.cycleLeft:
            return windows.count > 1 ? { cycleWindow(direction: -1) } : nil
        case MainRowOrder.cycleRight:
            return windows.count > 1 ? { cycleWindow(direction: 1) } : nil
        case MainRowOrder.spawn:
            return { showSpawnPicker = true }
        case MainRowOrder.arrange:
            guard windows.filter(\.enabled).count >= 2 else { return nil }
            return {
                // Three-mode cycle: horizontal → vertical → grid → horizontal.
                // Grid mode (added 2026-05-06) is the natural pick for 4+
                // windows where vertical strips get too narrow to read.
                switch phoneLayoutOverride {
                case "horizontal": phoneLayoutOverrideRaw = "vertical"
                case "vertical":   phoneLayoutOverrideRaw = "grid"
                default:           phoneLayoutOverrideRaw = "horizontal"
                }
                manualLayoutSticky = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        case MainRowOrder.broadcast:
            return BroadcastPromptPlan.canOpen(windows: windows, isConnected: client.isConnected)
                ? { openBroadcast(draft: textInputValue) } : nil
        case MainRowOrder.photo:
            return { showingImageSourceSheet = true }
        case MainRowOrder.prompts:
            let canFire = client.isConnected && !client.promptLibrary.isEmpty && selectedWindowId != nil
            return canFire ? { showPromptsPickerSheet = true } : nil
        case MainRowOrder.keyboard:
            return {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showTextInput.toggle()
                    if !showTextInput { textInputValue = "" }
                }
            }
        case MainRowOrder.return:
            return selectedWindowId != nil ? { submitOrPressReturn() } : nil
        default:
            return nil
        }
    }

    /// What a hold-without-drag does: the long presses the buttons had
    /// before the drag took the gesture (Q-65).
    private func mainRowHoldAction(_ id: String) -> (() -> Void)? {
        switch id {
        case MainRowOrder.arrange:
            return {
                realignWindows()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        case MainRowOrder.keyboard:
            // §35 Cross-app paste — hold the keyboard button to read iPhone's
            // clipboard and ship it straight to the selected window via
            // send_text. Skipped silently if no window selected OR clipboard
            // is empty — the accessibility hint documents the gesture.
            return { pasteClipboardToSelectedWindow() }
        default:
            return nil
        }
    }

    private func micButton(sizes: MainRowSizes) -> some View {
        // Push to talk — icon-only, and the one tinted tile in the row
        // so the primary action wins it (Q-62): the recording amber
        // token at low alpha, never a solid rectangle. Live adds a
        // 2 pt stroke and a stop square. Red stays for "no mic".
        Button {
            if isRecording {
                onStopRecording()
            } else {
                onStartRecording()
            }
        } label: {
            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(colors.recording)
                .frame(width: sizes.pttW, height: sizes.btnH)
                .background(colors.recording.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(colors.recording, lineWidth: isRecording ? 2 : 0)
                )
        }
        .accessibilityLabel(isRecording ? "Stop recording" : "Push to talk")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func mainRowItem(_ id: String, sizes: MainRowSizes) -> some View {
        switch id {
        case MainRowOrder.cycleLeft:
            Button { mainRowTapAction(id)?() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(windows.count > 1 ? colors.textPrimary : colors.textFaint)
                    .frame(width: sizes.navW, height: sizes.navH)
                    .background(colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    // The pill and the row width stay as they are; only
                    // the tappable shape grows to 44 pt (Q-62). A wider
                    // frame here pushed the row past the screen edge.
                    .contentShape(Rectangle().inset(by: -10))
            }
            .disabled(windows.count <= 1)
            .accessibilityLabel("Previous window")
            .accessibilityAddTraits(.isButton)
        case MainRowOrder.cycleRight:
            Button { mainRowTapAction(id)?() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(windows.count > 1 ? colors.textPrimary : colors.textFaint)
                    .frame(width: sizes.navW, height: sizes.navH)
                    .background(colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle().inset(by: -10))
            }
            .disabled(windows.count <= 1)
            .accessibilityLabel("Next window")
            .accessibilityAddTraits(.isButton)
        case MainRowOrder.spawn:
            Button { mainRowTapAction(id)?() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
                    .frame(width: sizes.auxW, height: sizes.auxH)
                    .background(colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .accessibilityLabel("New window")
            .accessibilityAddTraits(.isButton)
        case MainRowOrder.arrange:
            // Arrange — phone-only display toggle. Cycles through
            // Mac-layout (default, shows real Mac positions), columns
            // (side-by-side on phone), rows (stacked on phone). Does
            // NOT move windows on the Mac; just reorganizes the preview
            // here so overlapping/off-screen windows become distinct
            // cards when you need 'em.
            // Single button — tap cycles horizontal/vertical, hold-and-release
            // realigns (clears manual drag overrides + re-fires the
            // auto-chooser, see mainRowHoldAction). Combined into one slot
            // per `feedback_compact_ui` so the row doesn't overflow. nil isn't
            // a tap-cycle step anymore; the auto-chooser owns "no override" now.
            Button { mainRowTapAction(id)?() } label: {
                let icon: String = {
                    switch phoneLayoutOverride {
                    case "horizontal": return "rectangle.split.3x1"
                    case "vertical":   return "rectangle.split.1x3"
                    case "grid":       return "rectangle.grid.2x2"
                    default:           return "rectangle.3.group"
                    }
                }()
                // ZStack with a text fallback so the button is never
                // blank if the SF Symbol fails to draw — which has
                // happened when the icon name churns mid-redraw
                // (cycling between rectangle.split.3x1/1x3/group).
                // The text sits behind the icon, hidden when the icon
                // renders correctly.
                ZStack {
                    Text("⊞")
                        .font(.system(size: 14, weight: .semibold))
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        // Stable identity per icon name forces a clean
                        // redraw instead of a partial swap that can
                        // leave the symbol blank.
                        .id("arrange-\(icon)")
                        .accessibilityLabel("Arrange windows")
                }
                .foregroundStyle(windows.count >= 2 ? colors.textPrimary : colors.textFaint)
                .frame(width: sizes.auxW, height: sizes.auxH)
                .background(colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(windows.filter(\.enabled).count < 2)
            .accessibilityLabel("Arrange windows")
            .accessibilityHint("Double tap to cycle layout. Hold and release to realign; hold and drag to move the button.")
            .accessibilityAddTraits(.isButton)
        case MainRowOrder.broadcast:
            // Broadcast, beside the mic by default: the same sheet the bar
            // opened, as one icon tile (the owner wanted no extra row).
            let canBroadcast = BroadcastPromptPlan.canOpen(windows: windows, isConnected: client.isConnected)
            Button { mainRowTapAction(id)?() } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(canBroadcast ? colors.textPrimary : colors.textFaint)
                    .frame(width: sizes.bcW, height: sizes.auxH)
                    .background(colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!canBroadcast)
            .accessibilityLabel("Broadcast prompt")
            .accessibilityInputLabels(["Broadcast", "Broadcast Prompt"])
            .accessibilityHint("Choose terminal windows and send the same prompt to each one")
            .accessibilityAddTraits(.isButton)
        case MainRowOrder.photo:
            Button { mainRowTapAction(id)?() } label: {
                Image(systemName: pendingImage.hasPendingImage ? "photo.fill" : "photo")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(pendingImage.hasPendingImage ? colors.buttonPrimary : colors.textPrimary)
                    .frame(width: sizes.btnW, height: sizes.btnH)
                    .background(colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .accessibilityLabel(pendingImage.hasPendingImage ? "Attached image, tap to change" : "Attach image")
            .accessibilityAddTraits(.isButton)
        case MainRowOrder.prompts:
            let canFire = client.isConnected && !client.promptLibrary.isEmpty && selectedWindowId != nil
            Button { mainRowTapAction(id)?() } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(canFire ? colors.textPrimary : colors.textFaint)
                    .frame(width: sizes.auxW, height: sizes.auxH)
                    .background(colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!canFire)
            .accessibilityLabel("Prompts")
            .accessibilityAddTraits(.isButton)
        case MainRowOrder.keyboard:
            Button { mainRowTapAction(id)?() } label: {
                Image(systemName: showTextInput ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(colors.textPrimary)
                    .frame(width: sizes.auxW, height: sizes.auxH)
                    .background(colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .accessibilityLabel(showTextInput ? "Hide keyboard" : "Show keyboard")
            .accessibilityHint("Hold and release to paste from iPhone clipboard; hold and drag to move the button")
            .accessibilityAddTraits(.isButton)
        case MainRowOrder.return:
            Button { mainRowTapAction(id)?() } label: {
                Image(systemName: "return")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(selectedWindowId != nil ? colors.textPrimary : colors.textFaint)
                    .frame(width: sizes.btnW, height: sizes.btnH)
                    .background(colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(selectedWindowId == nil)
            .accessibilityLabel("Send")
            .accessibilityAddTraits(.isButton)
        default:
            EmptyView()
        }
    }

    private var broadcastPromptButton: some View {
        let canOpen = BroadcastPromptPlan.canOpen(
            windows: windows,
            isConnected: client.isConnected
        )
        return Button {
            openBroadcast(draft: textInputValue)
        } label: {
            // US-113 — the bar shows only while connected with windows, so the
            // one way it is disabled is that none of them is a terminal.
            // Owner: the bar was too large. One compact line; Settings →
            // Main Row Buttons → Broadcast Bar hides it altogether.
            Label(canOpen ? "Broadcast Prompt" : "Broadcast — no terminals open",
                  systemImage: "dot.radiowaves.left.and.right")
                .font(.system(size: isPortrait ? 13 : 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: isPortrait ? 32 : 28)
        }
        .accessibilityInputLabels(["Broadcast", "Broadcast Prompt"])
        .buttonStyle(.borderedProminent)
        .tint(colors.buttonPrimary)
        .disabled(!canOpen)
        .accessibilityHint("Choose terminal windows and send the same prompt to each one")
        .padding(.horizontal, isPortrait ? 6 : 12)
    }

    /// Compact one-line description of any notable PTT/voice path state
    /// for the banner just above the main row. nil when nothing notable —
    /// the banner stays collapsed. (GH H.)
    var pttHealthBanner: PTTBannerInfo? {
        Self.classifyPTTBanner(isConnected: client.isConnected,
                               isRecording: isRecording,
                               whisperStatus: client.whisperStatus)
    }

    /// Pure classification — kept static so unit tests can drive every
    /// combination without standing up the SwiftUI view hierarchy.
    static func classifyPTTBanner(isConnected: Bool,
                                  isRecording: Bool,
                                  whisperStatus: WhisperState) -> PTTBannerInfo? {
        // Mid-press disconnect is the loudest failure mode — surface first.
        if isRecording && !isConnected {
            return PTTBannerInfo(
                icon: "wifi.exclamationmark",
                message: "Mac disconnected mid-press — falling back to local",
                tint: .red
            )
        }
        // Whisper failed on the Mac side — remote path will silently fall
        // through to local each press unless the user knows.
        if case .failed(let reason) = whisperStatus {
            return PTTBannerInfo(
                icon: "waveform.slash",
                message: "Whisper offline (\(reason)) — using local",
                tint: .orange
            )
        }
        // Whisper still warming up — the next press uses local until ready.
        // Only show this banner while the user is mid-press; otherwise it's
        // routine startup chatter.
        if isRecording {
            switch whisperStatus {
            case .preparing:
                return PTTBannerInfo(
                    icon: "hourglass",
                    message: "Whisper warming up — using local for this press",
                    tint: .secondary
                )
            case .downloading(let p):
                return PTTBannerInfo(
                    icon: "arrow.down.circle",
                    message: "Whisper downloading \(Int(p * 100))% — using local",
                    tint: .secondary
                )
            default:
                break
            }
        }
        return nil
    }

    /// Send `RequestContentMessage` for every windowId we want content for —
    /// the selected window in normal mode, OR both pair halves in QA mode.
    /// Mac handles each request independently; payloads land in
    /// per-windowId state via the receive-side write in TerminalContentMessage.
    private func requestActiveContent() {
        if let pair = manager.active.qaPair {
            client.send(RequestContentMessage(windowId: pair.targetId))
            client.send(RequestContentMessage(windowId: pair.terminalId))
            return
        }
        if let wid = selectedWindowId {
            client.send(RequestContentMessage(windowId: wid))
        }
    }

    /// True when the active backend has a QA pair set. Used to gate every
    /// piece of UI that targets a non-pair window so QA is a focus mode.
    private var isQAModeActive: Bool {
        manager.active.qaPair != nil
    }

    private func cycleWindow(direction: Int) {
        guard !isQAModeActive else { return }
        // Cycle through windows in the order the user SEES them — the persisted
        // drag-reorder grid (displayWindows), not the Mac's raw window order —
        // so prev/next steps to the visually-adjacent card.
        let ordered = displayWindows
        guard ordered.count > 1 else { return }
        let currentIndex = ordered.firstIndex(where: { $0.id == selectedWindowId }) ?? 0
        let nextIndex = (currentIndex + direction + ordered.count) % ordered.count
        let newId = ordered[nextIndex].id
        withAnimation(.spring(duration: 0.2)) {
            selectedWindowId = newId
        }
        client.send(SelectWindowMessage(windowId: newId))
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
            Spacer()
            if BuildInfo.current.short != "?" {
                Text("v\(BuildInfo.shortDisplay(BuildInfo.current))")
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

    /// The suggestion the Mac reports for the selected window, if any.
    private var activeAutosuggest: TerminalAutosuggest? {
        guard let wid = selectedWindowId else { return nil }
        return terminalAutosuggestById[wid]
    }

    /// The echo, but only while it is still about the selected window.
    private var activeLineEcho: String? {
        guard let echo = lineEcho, echo.windowId == selectedWindowId else { return nil }
        return echo.text
    }

    /// Accept a true trailing ghost completion: the Mac chooses the correct
    /// acceptance key, then the phone mirrors the resulting line locally.
    private func acceptAutosuggest() {
        guard let wid = selectedWindowId, let suggestion = activeAutosuggest else { return }
        // The Codex phrase is an empty-composer placeholder, not text that a
        // terminal can accept. Tapping it should focus the phone's real input
        // field; only a true trailing ghost completion gets a key injected.
        if AutosuggestDetector.isPromptMarkerOnly(suggestion.typed) {
            focusTextInput()
            return
        }
        // `send` returns false when there is no socket. Ignoring it is how an
        // accept became a tap that did nothing, with no trace on either peer:
        // the suggestion maps outlive a disconnect, so the row was still there
        // to tap long after the Mac could hear about it.
        guard client.send(QuickActionMessage(windowId: wid, action: "press_right")) else {
            print("[Quip] accept autosuggest DROPPED — no socket (window=\(wid))")
            errorToast = "Not connected — the Mac never got that"
            return
        }
        print("[Quip] accept autosuggest sent press_right (window=\(wid))")
        let line = suggestion.accepted
        textInputValue = line
        lineEcho = (windowId: wid, text: line)
        // Re-scrape so the ghost row clears once the Mac has taken the
        // keystroke — same 300ms the quick-action path already uses.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [client] in
            client.send(RequestContentMessage(windowId: wid))
        }
    }

    private var isPromptPlaceholderAutosuggest: Bool {
        guard let suggestion = activeAutosuggest else { return false }
        return AutosuggestDetector.isPromptMarkerOnly(suggestion.typed)
    }

    private func focusTextInput() {
        lineEcho = nil
        textInputValue = ""
        showTextInput = true
        DispatchQueue.main.async {
            textInputFocused = true
        }
    }

    /// The user typed over text that is already on the Mac's input line. Wipe
    /// the line now, at edit time, so what they eventually send is the whole
    /// line and not a second copy appended to the first.
    private func reconcileEcho(_ newValue: String) {
        guard InputLineSend.shouldClearMacLine(fieldText: newValue, lineEcho: activeLineEcho),
              let wid = lineEcho?.windowId
        else { return }
        client.send(QuickActionMessage(windowId: wid, action: "clear_input"))
        lineEcho = nil
    }

    /// The suggestion row above the field: the line the agent is completing,
    /// then its ghost text. Tapping anywhere on it accepts. Hidden once the
    /// user starts composing — their own text is the thing being sent then,
    /// and the suggestion completes the Mac's line, not the phone's.
    @ViewBuilder
    private var autosuggestRow: some View {
        // Gated on the live connection, not just on having a suggestion: the
        // per-window maps survive a disconnect, and a row that offers an action
        // the phone cannot perform is worse than no row.
        if let suggestion = activeAutosuggest, client.isAuthenticated,
           textInputValue.isEmpty, lineEcho == nil {
            Button { acceptAutosuggest() } label: {
                HStack(spacing: 0) {
                    Text(suggestion.typed)
                        .foregroundStyle(colors.textSecondary)
                    Text(suggestion.suggestion)
                        .foregroundStyle(colors.textSecondary.opacity(0.55))
                    Spacer(minLength: 6)
                    Image(systemName: "text.append")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.textSecondary)
                }
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.surface.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Accept suggestion: \(suggestion.suggestion)")
            .accessibilityHint("Types the greyed suggestion on the Mac")
        }
    }

    private var textInputBar: some View {
        VStack(spacing: 3) {
            autosuggestRow
            HStack(spacing: 6) {
                TextField("Type a prompt\u{2026}", text: $textInputValue)
                    .focused($textInputFocused)
                    .font(.system(size: 12, design: .monospaced))
                    // While the field mirrors the Mac's input line it is not a
                    // draft, it is a readout — dimmed so the two never look
                    // like the same thing.
                    .foregroundStyle(isEchoingMacLine ? colors.textSecondary : colors.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onChange(of: textInputValue) { _, newValue in reconcileEcho(newValue) }
                    .onSubmit { sendTextInput() }

                Button { sendTextInput() } label: {
                    // Return, not up-arrow, while the text is already on the
                    // Mac's line: the button submits what is there rather than
                    // typing anything.
                    Image(systemName: isEchoingMacLine
                          ? "return.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(canSubmitInput ? colors.buttonPrimary : colors.buttonDisabled)
                }
                .disabled(!canSubmitInput)
                .accessibilityLabel(isEchoingMacLine ? "Submit the line on the Mac" : "Send")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(colors.background)
    }

    /// True while the compose field is a readout of the Mac's input line rather
    /// than a draft — i.e. an accepted suggestion that has not been edited.
    private var isEchoingMacLine: Bool {
        InputLineSend.plan(fieldText: textInputValue, lineEcho: activeLineEcho) == .returnOnly
    }

    private func sendTextInput() {
        guard let windowId = selectedWindowId else { return }
        // `nil` plan = nothing typed. An image-only submit is still valid, so
        // only bail when there is no image either.
        let plan = InputLineSend.plan(fieldText: textInputValue, lineEcho: activeLineEcho)
        guard plan != nil || pendingImage.hasPendingImage else { return }
        textInputValue = ""
        lineEcho = nil
        // Ship the image first; only fire the text send AFTER the image has
        // actually been dispatched so the Mac processes them in order.
        sendPendingImageIfNeeded(windowId: windowId) { [client] in
            switch plan {
            case .none:
                break
            case .typeAndReturn(let text):
                client.send(SendTextMessage(windowId: windowId, text: text, pressReturn: true))
            case .returnOnly:
                // The Mac already has this text on its input line (the phone put
                // it there by accepting a suggestion). Typing it again would
                // double it, so submit what is there.
                client.send(QuickActionMessage(windowId: windowId, action: "press_return"))
            }
        }
    }

    /// Queue one reviewed prompt for every selected terminal on the active Mac.
    /// Returning the queued IDs lets the sheet keep only failed targets selected
    /// for retry, avoiding duplicate prompts after a partial queue. Each message
    /// keeps its own dedupe token.
    /// Queue one broadcast, one message per target: `paste_prompt` for an
    /// unmodified library prompt, so the Mac fills its placeholders for each
    /// window (US-107), and `send_text` otherwise. Returns the targets that
    /// were queued; the sheet keeps the rest selected for a retry.
    private func queueBroadcast(_ send: BroadcastSend) -> Set<String> {
        guard !send.text.isEmpty, !send.targetIDs.isEmpty else { return [] }
        var queued: [(windowID: String, name: String, messageID: UUID)] = []
        for windowID in send.targetIDs {
            let messageID = UUID()
            let sent: Bool
            switch send.route {
            // US-116 — raiseWindow: false, so the Mac does not raise every
            // iTerm2 window in turn (Terminal.app targets are raised anyway).
            case .pastePrompt(let promptID):
                sent = client.send(PastePromptMessage(id: promptID, windowId: windowID,
                                                      pressReturn: send.pressReturn, messageId: messageID,
                                                      raiseWindow: false))
            case .sendText(let text):
                sent = client.send(SendTextMessage(windowId: windowID, text: text,
                                                   pressReturn: send.pressReturn, messageId: messageID,
                                                   raiseWindow: false))
            }
            if sent { queued.append((windowID, broadcastTargetName(windowID), messageID)) }
        }
        guard !queued.isEmpty else { return [] }
        // The bar opens the sheet with the input line's text. Clear the line
        // only when that text is what reached every target.
        if queued.count == send.targetIDs.count,
           send.text == BroadcastPromptPlan.normalizedText(textInputValue) {
            textInputValue = ""
            lineEcho = nil
        }
        var expectsAck = true
        if case .pastePrompt(let promptID) = send.route {
            // US-112 — once per agent among the targets, not once per window.
            promptUsageJSON = PromptRanker.encode(BroadcastUsage.recording(
                promptID, contexts: queued.map { promptContext(forWindow: $0.windowID) },
                at: Date(), in: promptUsageStore()))
            if promptUsageMRUJSON != "{}" { promptUsageMRUJSON = "{}" }
            // A Mac from before US-115 does not ack `paste_prompt`; one that
            // does still confirms each target (BroadcastDelivery).
            expectsAck = false
        }
        trackBroadcast(BroadcastDelivery(text: send.text, source: send.source, targets: queued,
                                         expectsAck: expectsAck, startedAt: .now))
        return Set(queued.map(\.windowID))
    }

    /// The name a broadcast result line uses for a window: its folder, as the
    /// sheet lists it, else its title.
    private func broadcastTargetName(_ windowID: String) -> String {
        windows.first(where: { $0.id == windowID })?.displayTitle ?? windowID
    }

    /// Why Broadcast cannot open right now, or nil when it can (US-113).
    private var broadcastUnavailableReason: String? {
        if BroadcastPromptPlan.canOpen(windows: windows, isConnected: client.isConnected) { return nil }
        if !client.isConnected { return "Broadcast — not connected" }
        return "Broadcast — no terminals open"
    }

    /// Open the Broadcast sheet. Nothing is sent until the user taps Send.
    private func openBroadcast(draft: String, source: BroadcastSource? = nil, selection: Set<String>? = nil) {
        broadcastRequest = BroadcastSheetRequest(draft: draft, source: source, selection: selection)
    }

    /// A request from the Prompts hub (US-108) or a `quip://broadcast` link
    /// (US-114). Sheets in the way close first; one cannot present while
    /// another is still animating away.
    private func openBroadcast(_ link: BroadcastLink.Request) {
        let blocking = showSettings || showPromptsPickerSheet || showSlashSearch || broadcastRequest != nil
        showSettings = false
        showPromptsPickerSheet = false
        showSlashSearch = false
        broadcastRequest = nil
        let open = {
            guard let promptID = link.promptID else {
                openBroadcast(draft: link.text ?? "")
                return
            }
            guard let entry = client.promptLibrary.first(where: { $0.id == promptID }) else {
                showBroadcastToast("No prompt “\(promptID)” on this Mac")
                openBroadcast(draft: "")
                return
            }
            openBroadcast(draft: entry.body, source: BroadcastSource(promptID: entry.id, body: entry.body))
        }
        if blocking {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.6))
                open()
            }
        } else {
            open()
        }
    }

    /// The Broadcast Quick Button (US-109). When the sheet cannot open, it
    /// says why instead of doing nothing (US-113).
    private func fireBroadcastKey() {
        if let reason = broadcastUnavailableReason {
            broadcastWarningTick += 1
            showBroadcastToast(reason)
            return
        }
        openBroadcast(draft: textInputValue)
    }

    private func showBroadcastToast(_ message: String) {
        errorToast = message
        broadcastToastTask?.cancel()
        broadcastToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, errorToast == message else { return }
            errorToast = nil
        }
    }

    private var toastTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    /// Show `delivery` in the toast area, replacing any earlier one, and mark
    /// targets that have not answered by the deadline (US-111).
    private func trackBroadcast(_ delivery: BroadcastDelivery) {
        broadcastDelivery = delivery
        let startedAt = delivery.startedAt
        guard !delivery.isSettled else {
            hideBroadcastResult(startedAt, after: 4)
            return
        }
        broadcastDeadlineTask?.cancel()
        broadcastDeadlineTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(BroadcastDelivery.deadline + 0.05))
            guard !Task.isCancelled, broadcastDelivery?.startedAt == startedAt else { return }
            broadcastDelivery?.expire(at: .now)
            let hasRetry = broadcastDelivery?.retryWindowIDs.isEmpty == false
            hideBroadcastResult(startedAt, after: hasRetry ? 15 : 4)
        }
    }

    /// A `send_text_ack` arrived; count it if it belongs to the last broadcast.
    private func confirmBroadcastTarget(_ messageID: UUID) {
        guard var delivery = broadcastDelivery else { return }
        guard delivery.confirm(messageID: messageID) else { return }
        broadcastDelivery = delivery
        if delivery.isSettled && delivery.retryWindowIDs.isEmpty {
            hideBroadcastResult(delivery.startedAt, after: 4)
        }
    }

    /// An `error` named one of the last broadcast's messages (US-115): that
    /// target failed now, without waiting for the deadline, and the line
    /// stays long enough to tap Retry.
    private func failBroadcastTarget(_ messageID: UUID) {
        guard var delivery = broadcastDelivery else { return }
        guard delivery.fail(messageID: messageID) else { return }
        broadcastDelivery = delivery
        hideBroadcastResult(delivery.startedAt, after: 15)
    }

    private func hideBroadcastResult(_ startedAt: Date, after seconds: TimeInterval) {
        broadcastHideTask?.cancel()
        broadcastHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, broadcastDelivery?.startedAt == startedAt else { return }
            broadcastDelivery = nil
        }
    }

    /// US-111 — the last broadcast's result, one line under the error toast.
    /// A tap reopens the sheet with only the terminals that did not confirm,
    /// or dismisses the line when every target answered.
    @ViewBuilder
    private var broadcastResultLine: some View {
        if let delivery = broadcastDelivery {
            let retryIDs = delivery.retryWindowIDs
            Button {
                broadcastDelivery = nil
                if !retryIDs.isEmpty {
                    openBroadcast(draft: delivery.text, source: delivery.source, selection: Set(retryIDs))
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: !retryIDs.isEmpty ? "exclamationmark.triangle.fill"
                          : delivery.isSettled ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                    Text(delivery.summary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !retryIDs.isEmpty {
                        Text("Retry").bold()
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background((retryIDs.isEmpty ? Color.black : Color.orange).opacity(0.8))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .accessibilityHint(retryIDs.isEmpty
                               ? "Dismisses this message"
                               : "Opens Broadcast with only the terminals that did not confirm selected")
            .transition(toastTransition)
        }
    }

    /// True when there's something for the up-arrow / Return button to
    /// submit — typed text (after trim) or a queued image. Pure read so
    /// both the up-arrow's `.disabled` check and `submitOrPressReturn()`'s
    /// branch read the same condition.
    private var canSubmitInput: Bool {
        InputLineSend.plan(fieldText: textInputValue, lineEcho: activeLineEcho) != nil
            || pendingImage.hasPendingImage
    }

    /// Unified action behind the main-row Return ⏎ button. Mirrors the
    /// up-arrow submit when there's typed text or a queued image so the
    /// two affordances stop disagreeing on what "send" means. When the
    /// input is empty, falls through to the bare press_return keystroke
    /// — that path is what makes Return useful when Claude is sitting
    /// at a confirmation prompt and the user just wants to advance it
    /// without typing anything.
    private func submitOrPressReturn() {
        if canSubmitInput {
            sendTextInput()
            return
        }
        guard let wid = selectedWindowId else { return }
        sendPendingImageIfNeeded(windowId: wid) { [client] in
            client.send(QuickActionMessage(windowId: wid, action: "press_return"))
        }
    }

    /// §26 — build the iPhone-side diagnostics snapshot. Captured at
    /// shake time + frozen for the duration of the sheet so values
    /// don't churn while the user is reading. Pulls from
    /// `WebSocketClient.recentConnectionEvents` ring buffer for the
    /// last 30 lifecycle events.
    @MainActor
    fileprivate func buildDiagnosticsSnapshot() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let appVersion = info["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = BuildInfo.current.commit.map { commit in
            "\(info["CFBundleVersion"] as? String ?? "?") \(commit) \(BuildInfo.current.date ?? "")"
        } ?? (info["CFBundleVersion"] as? String ?? "?")
        let activeName = manager.paired.first(where: { $0.id == manager.activeBackendID })?.name
        let activeBackendID = manager.activeBackendID.isEmpty ? nil : manager.activeBackendID
        let activeReachability = reachabilityLabel(manager.sessions[manager.activeBackendID]?.reachability)
        let selectedWindow = selectedWindowId.flatMap { id in windows.first(where: { $0.id == id }) }
        let contentWindowId = currentDiagnosticsContentWindowId()
        let contentText = contentWindowId.flatMap { terminalContentTextById[$0] }
            ?? (contentWindowId == terminalContentWindowId ? terminalContentText : nil)
        let contentScreenshot = contentWindowId.flatMap { terminalContentScreenshotById[$0] }
            ?? (contentWindowId == terminalContentWindowId ? terminalContentScreenshot : nil)
        let contentURLs = contentWindowId.flatMap { terminalContentURLsById[$0] }
            ?? (contentWindowId == terminalContentWindowId ? terminalContentURLs : nil)
        let contentUpdatedAt = contentWindowId.flatMap { terminalContentUpdatedAtById[$0] }
            ?? (contentWindowId == terminalContentWindowId ? terminalContentUpdatedAt : nil)
        let now = Date()
        let contentAgeSeconds = contentUpdatedAt.map {
            max(0, Int(now.timeIntervalSince($0).rounded(.down)))
        }
        let contentHasScreenshot = contentWindowId.map { _ in contentScreenshot?.isEmpty == false }
        let latestSendTextRoutePath = client.latencySamples
            .last(where: { $0.path == "pasteText" || $0.path == "sendText" })?
            .path
        let snapshot = DiagnosticsSnapshotFormatter.Input(
            appVersion: appVersion,
            buildNumber: buildNumber,
            isConnected: client.isConnected,
            isConnecting: client.isConnecting,
            isAuthenticated: client.isAuthenticated,
            lastError: client.lastError,
            lastDisconnectReason: client.lastDisconnectReason,
            serverURL: client.serverURL?.absoluteString,
            pairedCount: manager.paired.count,
            activeBackendName: activeName,
            connectionEvents: client.recentConnectionEvents,
            activeBackendID: activeBackendID,
            activeBackendReachability: activeReachability,
            selectedWindowID: selectedWindowId,
            selectedWindowName: selectedWindow?.name,
            selectedWindowCLI: selectedWindow.map { ($0.cliKind ?? .shell).rawValue },
            terminalContentWindowID: contentWindowId,
            terminalContentAgeSeconds: contentAgeSeconds,
            terminalContentTextLength: contentText?.count,
            terminalContentHasScreenshot: contentHasScreenshot,
            terminalContentURLCount: contentURLs?.count,
            latestSendTextRoutePath: latestSendTextRoutePath
        )
        return DiagnosticsSnapshotFormatter.format(snapshot, now: now)
    }

    private func currentDiagnosticsContentWindowId() -> String? {
        if let selectedWindowId,
           terminalContentTextById[selectedWindowId] != nil
            || terminalContentScreenshotById[selectedWindowId] != nil
            || terminalContentURLsById[selectedWindowId] != nil {
            return selectedWindowId
        }
        return terminalContentWindowId
    }

    private func reachabilityLabel(_ reachability: BackendSession.Reachability?) -> String? {
        switch reachability {
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .unreachable:
            return "unreachable"
        case .needsAuth:
            return "needsAuth"
        case nil:
            return nil
        }
    }

    /// §35 — long-press on the keyboard main-row button reads the iPhone's
    /// system clipboard and ships it to the selected window via send_text
    /// with `pressReturn: false`. Triggers iOS's per-app paste-permission
    /// prompt the first time the user does it (system standard). Skips
    /// silently when no window selected or clipboard is empty/non-text;
    /// the haptic at the end gives feedback even when nothing was pasted.
    /// Truncated to a 32 KiB ceiling because larger payloads should use
    /// the dedicated text-input panel + send path with proper batching.
    @MainActor
    fileprivate func pasteClipboardToSelectedWindow() {
        guard let wid = selectedWindowId, !wid.isEmpty else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        guard let raw = UIPasteboard.general.string, !raw.isEmpty else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        let text = Self.clipText(raw, maxBytes: 32 * 1024)
        client.send(SendTextMessage(windowId: wid, text: text, pressReturn: false))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Cap clipboard payload at `maxBytes` UTF-8 bytes. Trims by character
    /// (not byte) so we never split a multi-byte glyph. Pure helper so a
    /// unit test can drive boundary cases without UIPasteboard.
    static func clipText(_ s: String, maxBytes: Int) -> String {
        if s.utf8.count <= maxBytes { return s }
        var out = ""
        var bytes = 0
        for ch in s {
            let n = String(ch).utf8.count
            if bytes + n > maxBytes { break }
            out.append(ch)
            bytes += n
        }
        return out
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
            // Encode to JPEG-0.85 by default — ~30% smaller than the
            // previous JPEG-0.95 default and the broadest Anthropic-API-
            // compatible format. PNG is preserved when the source declared
            // image/png (lossless screenshots stay pixel-perfect).
            //
            // HEIC was tried (commit 684956b) but rolled back: the
            // Anthropic API rejects image/heic with HTTP 400
            // "Could not process image" — supported types are JPEG, PNG,
            // GIF, WEBP only. WebP would be a better win but
            // CGImageDestination's WebP encoder didn't ship until iOS 18
            // and the project targets iOS 17.
            let rawData: Data?
            let initialMime: String
            if mime == "image/png" {
                rawData = image.pngData()
                initialMime = "image/png"
            } else {
                rawData = image.jpegData(compressionQuality: 0.85)
                initialMime = "image/jpeg"
            }
            guard let rawData else {
                DispatchQueue.main.async { [weak pendingImage] in
                    pendingImage?.markError("couldn't encode image")
                    afterSend?()
                }
                return
            }
            DispatchQueue.main.async { [weak pendingImage, c = rawData.count, m = initialMime] in
                pendingImage?.setDebugStage("encoded \(c)B (\(m))")
            }
            do {
                let (data, finalMime) = try recompressor.recompress(rawData: rawData, declaredMime: initialMime)
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

    /// Q-87: Claude's previews for the selected terminal sit above its content.
    private var terminalContentView: some View {
        let previews = ClaudePreviewLogic.visible(client.claudePreviews, selectedWindowId: selectedWindowId,
                                                  knownWindowIds: Set(windows.map(\.id)))
        return VStack(spacing: 4) {
            if !previews.isEmpty {
                ClaudePreviewStrip(
                    items: previews,
                    onOpen: { openClaudePreview = $0 },
                    onDismiss: { item in
                        client.send(ClaudePreviewDismissMessage(id: item.id, closeOnDesktop: item.hasDesktopWindow))
                        client.claudePreviews.removeAll { $0.id == item.id }
                    })
            }
            terminalTextContentView
        }
        .fullScreenCover(item: $openClaudePreview) { item in
            ClaudePreviewViewer(item: item, client: client)
        }
    }

    private var terminalTextContentView: some View {
        let wid = selectedWindowId ?? ""
        let text = terminalContentTextById[wid] ?? terminalContentText ?? ""
        let screenshot = terminalContentScreenshotById[wid] ?? terminalContentScreenshot
        let urls = terminalContentURLsById[wid] ?? terminalContentURLs ?? []
        return InlineTerminalContent(
            content: text,
            screenshot: screenshot,
            urls: urls,
            autosuggest: activeAutosuggest,
            windowName: windows.first(where: { $0.id == selectedWindowId })?.name ?? "",
            windowColor: windows.first(where: { $0.id == selectedWindowId }).map { Color(hex: $0.color) } ?? colors.textSecondary,
            windowId: selectedWindowId,
            lastUpdate: terminalContentUpdatedAtById[wid],
            isExpanded: $isTerminalExpanded,
            onRefresh: {
                if let wid = selectedWindowId { onRequestContent(wid) }
            },
            onSendAction: { action, fingerprint in
                // Route the shared action through the live suggestion type:
                // placeholder taps focus the phone field, while real shell
                // ghost text is accepted on the Mac.
                if action == "press_right", activeAutosuggest != nil {
                    if isPromptPlaceholderAutosuggest {
                        focusTextInput()
                    } else {
                        acceptAutosuggest()
                    }
                    return
                }
                if let wid = selectedWindowId {
                    client.send(QuickActionMessage(windowId: wid, action: action, promptFingerprint: fingerprint))
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
        // The chips are the whole multi-display affordance, and they cost zero
        // vertical space on a one-display, one-desktop Mac (see `filterChips`).
        // Inside windowLayout rather than at each of its four call sites so
        // every layout — portrait, landscape, expanded — gets them for free.
        VStack(spacing: 0) {
            filterChips
            minimizedTray
            windowCanvas
        }
    }

    /// A window the tray is about to close; drives the confirmation alert.
    @State private var trayCloseCandidate: MinimizedTray.Entry?
    @State private var showTrayClose = false

    /// Q-53 — the dock-like tray: one pill per window the Mac minimized for
    /// the phone. Tapping a pill restores and raises it; the small x asks,
    /// then closes the terminal. Absent when nothing is minimized, so the
    /// grid pays no height for it; the cards stay in the grid too, marked.
    @ViewBuilder
    private var minimizedTray: some View {
        let entries = MinimizedTray.entries(windows)
        if !entries.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    Image(systemName: "dock.rectangle")
                        .font(.system(size: 11))
                        .foregroundStyle(colors.textFaint)
                        .accessibilityLabel("Minimized windows")
                    // One pill, one tap target the size of the pill (a 9 pt x
                    // beside it was an 18 pt target that mis-tapped into
                    // Restore). Close is the long-press action, as on the card.
                    ForEach(entries) { entry in
                        Button {
                            restoreMinimizedWindow(entry.id)
                        } label: {
                            Label(entry.title, systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .foregroundStyle(Color(hex: entry.color))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color(hex: entry.color).opacity(0.14))
                                .clipShape(Capsule())
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Restores and raises the window on the Mac")
                        .accessibilityAction(named: "Close \(entry.title)") {
                            trayCloseCandidate = entry
                            showTrayClose = true
                        }
                        .contextMenu {
                            Button("Close Terminal", systemImage: "xmark.circle", role: .destructive) {
                                trayCloseCandidate = entry
                                showTrayClose = true
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)
            .alert("Close \(trayCloseCandidate?.title ?? "window")?",
                   isPresented: $showTrayClose,
                   presenting: trayCloseCandidate) { entry in
                Button("Cancel", role: .cancel) {}
                Button("Close Terminal", role: .destructive) {
                    client.send(CloseWindowMessage(windowId: entry.id))
                }
            } message: { _ in
                Text("Kills any running command in that terminal. This can't be undone.")
            }
        }
    }

    /// Bring a minimized window back (Q-53): select it here and ask the Mac
    /// to focus it, which un-minimizes before raising (Q-23). Same side
    /// effects as tapping its card.
    private func restoreMinimizedWindow(_ windowId: String) {
        withAnimation(.spring(duration: 0.2)) { selectedWindowId = windowId }
        if followFrontmost { followFrontmost = false }
        client.send(SelectWindowMessage(windowId: windowId))
    }

    /// Visibility and display filters on ONE 26pt row. Labs-gated, off by
    /// default (`LabsFlags.windowFilters`).
    ///
    /// Two axes, ANDed: whether a window is drawn on the desk right now is not
    /// which monitor it is on, a window has one of each, and the grid shows the
    /// windows both filters allow. Each side carries its own "All …" chip, and
    /// every count is scoped to what the other side is allowing, so the row
    /// states the rule rather than leaving it to be inferred from missing cards.
    ///
    /// They used to be two stacked rows, so a multi-display Mac with hidden
    /// windows spent 52pt of the grid on chrome. They are also both horizontal
    /// scrolls, so a single row loses nothing: what does not fit scrolls,
    /// exactly as it already did.
    ///
    /// The visibility side collapses to a single chip naming the active filter,
    /// to keep the row short on the phone.
    ///
    /// Off by default because the row's default pick REMOVED cards: the
    /// visibility axis defaulted to "On Screen", so minimizing a tracked
    /// terminal made it vanish from the phone with nothing on screen saying
    /// why. Off, every window the Mac broadcasts is rendered.
    @ViewBuilder
    private var filterChips: some View {
        if labsWindowFilters, activeSpaces.count > 1 || displays.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    spaceChipGroup
                    if activeSpaces.count > 1 && displays.count > 1 {
                        // The two kinds filter different things; without a rule
                        // they read as one undifferentiated run of capsules.
                        Divider().frame(height: 12)
                    }
                    displayChipGroup
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
            .frame(height: 26)
        }
    }

    /// Windows the OTHER axis is currently letting through.
    ///
    /// Every chip count is computed against these, never against the raw list.
    /// The two filters AND together, so a display chip that counted every window
    /// on that display while a desktop filter was also narrowing the grid
    /// described a set the grid was not showing: the badges never summed to the
    /// number of cards, and the row gave no clue that the other filter was the
    /// reason. Counted this way, the badges ARE the rule — each side shows the
    /// breakdown of what the other side is already allowing, and a 0 says
    /// plainly "nothing here, given the other filter".
    private var windowsPassingSpaceFilter: [WindowState] {
        guard let id = effectiveSpaceID else { return displayWindows }
        return displayWindows.filter { $0.spaceID == id }
    }

    private var windowsPassingDisplayFilter: [WindowState] {
        guard let id = pinnedDisplayID else { return displayWindows }
        return displayWindows.filter { effectiveDisplayID($0) == id }
    }

    /// The display filter actually in force: the chip pick while the Labs row
    /// is on, and nothing at all while it is off. The per-backend selection
    /// itself is left untouched in `UserDefaults`, so turning the row back on
    /// restores the monitor the user had pinned rather than resetting it.
    private var pinnedDisplayID: String? {
        labsWindowFilters ? selectedDisplayID : nil
    }

    /// Compact per-monitor filter. One chip per display plus "All Displays",
    /// only when the Mac actually has more than one display — a single-display
    /// desk sees nothing at all, not a row with one useless chip.
    @ViewBuilder
    private var displayChipGroup: some View {
        if displays.count > 1 {
            ForEach(displays) { display in
                filterChip(title: display.name, icon: Self.displayChipIcon,
                           count: windowsPassingSpaceFilter
                               .filter { effectiveDisplayID($0) == display.id }.count,
                           isOn: selectedDisplayID == display.id) {
                    selectDisplay(display.id)
                }
            }
            // Named, not bare "All": with an "All Windows" chip on the same
            // row, one unqualified "All" read as a reset for both.
            filterChip(title: "All Displays", icon: Self.displayChipIcon,
                       count: windowsPassingSpaceFilter.count,
                       isOn: selectedDisplayID == nil) {
                selectDisplay(nil)
            }
        }
    }

    /// Visibility buckets holding at least one window. A bucket the user has
    /// nothing in would only offer a chip leading to a blank grid, and dropping
    /// the empties can take the row back down to one — at which point it hides
    /// entirely, exactly like `displayChipGroup` on a single-display desk.
    ///
    /// Deliberately computed from ALL windows, not from the display filter's
    /// survivors: a filter row that reshuffles itself as you use it is worse
    /// than one that keeps a stable set of chips and shows a 0 count.
    private var activeSpaces: [SpaceState] {
        SpaceActivity.active(spaces: spaces, windows: windows)
    }

    /// SF Symbols for the two chip kinds. They used to share `display`, which
    /// made a visibility chip and a monitor chip indistinguishable at a glance —
    /// the main reason the area read as noise rather than as two filters.
    private static let spaceChipIcon = "macwindow.on.rectangle"
    private static let displayChipIcon = "display"

    /// The visibility filter: one chip when collapsed, the full set when
    /// expanded.
    ///
    /// Collapsed is the default to keep the row short. The collapsed chip
    /// carries a chevron and names the active filter, so the row always says
    /// what the grid is showing even at its smallest.
    @ViewBuilder
    private var spaceChipGroup: some View {
        if activeSpaces.count > 1 {
            if spaceChipsExpanded {
                ForEach(activeSpaces) { space in
                    filterChip(title: space.name, icon: Self.spaceChipIcon,
                               count: windowsPassingDisplayFilter
                                   .filter { $0.spaceID == space.id }.count,
                               isOn: effectiveSpaceID == space.id) {
                        selectSpace(space.id)
                    }
                }
                filterChip(title: "All Windows", icon: Self.spaceChipIcon,
                           count: windowsPassingDisplayFilter.count,
                           isOn: effectiveSpaceID == nil) {
                    selectSpace(nil)
                }
                // Collapsing is otherwise only reachable by picking a filter,
                // which forces a selection change just to tidy the row.
                filterChip(title: "", icon: "chevron.left", count: nil, isOn: false) {
                    withAnimation(.easeOut(duration: 0.15)) { spaceChipsExpanded = false }
                }
            } else {
                filterChip(
                    title: SpaceActivity.collapsedTitle(activeSpaces: activeSpaces,
                                                        effectiveSpaceID: effectiveSpaceID),
                    icon: Self.spaceChipIcon,
                    count: SpaceActivity.collapsedCount(windows: windowsPassingDisplayFilter,
                                                        effectiveSpaceID: effectiveSpaceID),
                    isOn: effectiveSpaceID != nil,
                    trailingIcon: "chevron.right"
                ) {
                    withAnimation(.easeOut(duration: 0.15)) { spaceChipsExpanded = true }
                }
            }
        }
    }

    /// Pick a bucket and collapse in one gesture — an expanded row that stayed
    /// open after a choice would cost the space the collapse exists to save.
    private func selectSpace(_ id: String?) {
        withAnimation(.easeOut(duration: 0.15)) {
            selectedSpaceID = id
            spaceChipsExpanded = false
        }
    }

    /// One filter capsule, used by both axes. `icon` distinguishes a visibility
    /// chip from a monitor chip; `count` is optional so a bare control (the
    /// collapse affordance) can reuse the same shape instead of growing a
    /// second chip style; `trailingIcon` carries the disclosure chevron when
    /// collapsed.
    private func filterChip(title: String, icon: String, count: Int?, isOn: Bool,
                            trailingIcon: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .semibold))
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 10, weight: isOn ? .semibold : .regular))
                        .lineLimit(1)
                }
                if let count {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(isOn ? Color.white.opacity(0.75) : colors.textFaint)
                }
                if let trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(isOn ? Color.white.opacity(0.75) : colors.textFaint)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(isOn ? Color.white : colors.textFaint)
            .background(
                Capsule().fill(isOn ? Color.blue.opacity(0.75) : colors.surface.opacity(0.6))
            )
            .overlay(
                Capsule().strokeBorder(isOn ? Color.clear : colors.surfaceBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    /// Write the chip choice through to the session so it persists per backend
    /// and survives a backend switch.
    private func selectDisplay(_ id: String?) {
        withAnimation(.easeOut(duration: 0.15)) { selectedDisplayID = id }
        manager.active.updateSelectedDisplay(id)
    }

    /// A window's display, defaulting to the primary. An older Mac build sends
    /// no `displayID`, and everything it sends is normalized against the
    /// primary — so treating nil as primary keeps those builds rendering
    /// exactly as before.
    private func effectiveDisplayID(_ window: WindowState) -> String? {
        window.displayID ?? displays.first(where: { $0.isPrimary })?.id ?? displays.first?.id
    }

    /// The display the chips are currently showing, or nil for "All Displays".
    private var activeDisplay: DisplayState? {
        guard let id = pinnedDisplayID else { return nil }
        return displays.first { $0.id == id }
    }

    /// Aspect of the canvas the windows are drawn on: the chosen display's own
    /// aspect, or the whole desk's span when "All Displays" is showing. Falls
    /// back to `screenAspect` (the primary) for a single-display Mac.
    private var canvasAspect: Double {
        if let display = activeDisplay, display.aspect > 0 { return display.aspect }
        if displays.count > 1, spanAspect > 0 { return spanAspect }
        return screenAspect
    }

    /// The visibility filter actually in force — nothing at all while the Labs
    /// row is off. A pinned bucket whose last window just closed falls back to
    /// "All Windows" rather than stranding the user on an empty grid with the
    /// chip that got them there now gone.
    private var effectiveSpaceID: String? {
        guard labsWindowFilters else { return nil }
        return SpaceActivity.resolvedSelection(selectedSpaceID, activeSpaces: activeSpaces)
    }

    /// Every filter currently narrowing the grid, named the way its chip is.
    /// nil when nothing is filtering, so the caller can tell "the filters hid
    /// them" from "there is genuinely nothing".
    ///
    /// Both are listed when both are on: the AND is the part people miss, and
    /// naming one filter while another is also active is what makes the row
    /// look broken.
    private var activeFilterSummary: String? {
        var parts: [String] = []
        if let id = effectiveSpaceID,
           let space = activeSpaces.first(where: { $0.id == id }) {
            parts.append(space.name)
        }
        if let display = activeDisplay { parts.append(display.name) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " + ")
    }

    /// One reset for both axes. Two separate "All" chips meant clearing the
    /// view took two taps in two places, and neither chip admitted the other
    /// existed.
    private func clearWindowFilters() {
        selectSpace(nil)
        selectDisplay(nil)
    }

    /// Windows the grid shows: both filters applied. "All" on an axis is no
    /// filter on that axis.
    private var filteredWindows: [WindowState] {
        let bySpace = effectiveSpaceID.map { id in displayWindows.filter { $0.spaceID == id } } ?? displayWindows
        guard let id = pinnedDisplayID else { return bySpace }
        return bySpace.filter { effectiveDisplayID($0) == id }
    }

    /// Where a window is drawn on the current canvas.
    ///
    /// Mac-side frames are normalized against the window's OWN display, so
    /// showing one screen needs no conversion at all. The merged "All" canvas
    /// composes each display's `spanFrame` with the window's frame inside it —
    /// the exact inverse of the split the Mac performs (`DisplayGeometry`).
    private func canvasFrame(for window: WindowState) -> WindowFrame {
        guard pinnedDisplayID == nil, displays.count > 1,
              let display = displays.first(where: { $0.id == effectiveDisplayID(window) })
        else { return window.frame }
        return DisplayGeometry.spanFrame(ofWindow: window.frame, onDisplay: display.spanFrame)
    }

    private var windowCanvas: some View {
        GeometryReader { geo in
            let mac = Self.hostScreenRect(in: geo.size, aspect: CGFloat(canvasAspect))
            ZStack(alignment: .topLeading) {
                Color.clear

                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(colors.surface.opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(colors.surfaceBorder, lineWidth: 0.5)
                        )

                    if windows.isEmpty && client.isAuthenticated && !layoutReceived {
                        // Q-62: authenticated, first layout not here yet. Says
                        // so instead of "No windows" + New Window for a second.
                        VStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(colors.textFaint)
                            Text("Loading windows…")
                                .font(.system(size: 10))
                                .foregroundStyle(colors.textFaint)
                        }
                        .accessibilityElement(children: .combine)
                    } else if windows.isEmpty {
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
                                        .background(colors.buttonPrimary.opacity(0.7))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    } else if filteredWindows.isEmpty, let filterSummary = activeFilterSummary {
                        // The Mac has windows, just none that BOTH filters
                        // allow. This used to fire only for a pinned display, so
                        // a desktop filter that emptied the grid rendered blank
                        // and looked like a dead connection — and nothing said
                        // the two filters combine, which is exactly when that
                        // matters. Name every active filter and clear them all
                        // in one tap.
                        VStack(spacing: 6) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 20, weight: .light))
                                .foregroundStyle(colors.textFaint)
                            Text("Nothing on \(filterSummary)")
                                .font(.system(size: 10))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(colors.textFaint)
                            Button("Show everything") { clearWindowFilters() }
                                .font(.system(size: 11, weight: .medium))
                        }
                    } else {
                        ForEach(Array(filteredWindows.enumerated()), id: \.element.id) { index, window in
                            // A phone-side override (manual drag / auto-arrange)
                            // is already canvas-space, so it must NOT be run
                            // through the span composition again.
                            let effectiveFrame = phoneLayoutFrame(for: window, index: index,
                                                                  total: filteredWindows.count)
                                ?? canvasFrame(for: window)
                            let rect = windowRect(frame: effectiveFrame, in: mac.size, inset: 3)
                            let isDragging = draggingWindowId == window.id

                            // Ghost — faint placeholder at the original
                            // position so the user can see where the card
                            // came from while dragging it elsewhere.
                            if isDragging {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color(hex: window.color).opacity(0.3),
                                                  style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                    .frame(width: rect.width, height: rect.height)
                                    .position(x: rect.midX, y: rect.midY)
                                    .allowsHitTesting(false)
                            }

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
                                    // Q-62: the card has no pressed state, so a
                                    // tap is felt as well as seen. Only on a
                                    // real change, and never for a Mac-driven
                                    // follow (that path does not run here).
                                    if selectedWindowId != window.id {
                                        UISelectionFeedbackGenerator().selectionChanged()
                                    }
                                    withAnimation(.spring(duration: 0.2)) {
                                        selectedWindowId = window.id
                                    }
                                    // (wishlist §B16.) Manual tap pins this window — turns
                                    // off follow-Mac-frontmost so the next Mac focus change
                                    // doesn't pull the rug out from under the user. They
                                    // re-enable follow-mode via the Auto pill.
                                    if followFrontmost {
                                        followFrontmost = false
                                    }
                                    // Tell Mac to focus this window
                                    client.send(SelectWindowMessage(windowId: window.id))
                                },
                                onAction: { action in
                                    sendAction(windowId: window.id, action: action)
                                }
                            )
                            .frame(width: rect.width, height: rect.height)
                            .scaleEffect(isDragging ? 1.05 : 1.0)
                            .shadow(color: .black.opacity(isDragging ? 0.35 : 0),
                                    radius: isDragging ? 8 : 0, y: isDragging ? 4 : 0)
                            .position(x: rect.midX, y: rect.midY)
                            .offset(isDragging ? dragTranslation : .zero)
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
                            // Active drag floats above neighbors; otherwise
                            // attention dot wins (existing behavior).
                            .zIndex(isDragging ? 100
                                    : attentionCenter.windowsNeedingAttention.contains(window.id) ? 10 : 0)
                            // Drag-to-move (US-005). highPriorityGesture, not
                            // .gesture: WindowRectangle owns an inner
                            // .onTapGesture + .contextMenu, and SwiftUI gives
                            // those DESCENDANT gestures priority over an
                            // ANCESTOR .gesture — so a plain .gesture(DragGesture)
                            // here never claims the touch and the card won't
                            // drag. highPriorityGesture evaluates the drag first;
                            // minimumDistance:10 means a pure tap (no travel)
                            // fails the drag and falls through to onSelect, and a
                            // motionless long-press still opens the context menu.
                            // Also beats a ScrollView pan ancestor, if present.
                            .highPriorityGesture(
                                DragGesture(minimumDistance: 10)
                                    .onChanged { value in
                                        if draggingWindowId != window.id {
                                            draggingWindowId = window.id
                                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                        }
                                        dragTranslation = value.translation
                                    }
                                    .onEnded { value in
                                        let inset: CGFloat = 3
                                        let usableW = mac.size.width - inset * 2
                                        let usableH = mac.size.height - inset * 2
                                        let droppedX = (rect.midX + value.translation.width - inset) / usableW
                                        let droppedY = (rect.midY + value.translation.height - inset) / usableH
                                        let dropCenter = CGPoint(
                                            x: max(0, min(1, droppedX)),
                                            y: max(0, min(1, droppedY))
                                        )
                                        handleDrop(windowId: window.id, dropCenter: dropCenter)
                                        draggingWindowId = nil
                                        dragTranslation = .zero
                                    }
                            )
                        }
                    }
                }
                .frame(width: mac.width, height: mac.height)
                .offset(x: mac.minX, y: mac.minY)
                // (wishlist §B16.) Auto-follow pill, top-right corner of
                // the mac-screen rect. Tap toggles followFrontmost. Only
                // shown once windows exist — the empty-state already has
                // its own focal CTA and the pill would just be noise.
                .overlay(alignment: .topTrailing) {
                    if !windows.isEmpty {
                        autoFollowPill
                            .padding(6)
                    }
                }
            }
        }
    }

    /// Compact pill that toggles `followFrontmost`. Filled accent when on
    /// (phone is following Mac focus); outlined when off (phone is pinned
    /// to whatever the user last tapped). Icon-only per compact-UI rules.
    private var autoFollowPill: some View {
        Button {
            followFrontmost.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: followFrontmost ? "cursorarrow.rays" : "hand.point.up.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(followFrontmost ? .white : colors.textPrimary)
                .frame(width: 22, height: 22)
                .background(followFrontmost ? Color.accentColor : colors.surface.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(colors.surfaceBorder, lineWidth: 0.5)
                )
        }
        .accessibilityLabel(followFrontmost ? "Following Mac frontmost window. Tap to pin." : "Pinned to selected window. Tap to follow Mac.")
    }

    /// Largest rect with the given aspect ratio (width/height) that fits inside
    /// `size`, centered.
    ///
    /// The canvas is a scale model of the desk: every card is placed by
    /// multiplying a normalized frame by this rect, so the rect's aspect IS the
    /// mapping. It used to multiply the height by 1.45 in the letterboxed case
    /// "so the thumbnail isn't a narrow strip", which made the model lie by 45%
    /// in one axis — worst exactly where it is least affordable, on a wide desk.
    /// On a 3440x1440 ultrawide (aspect 2.39) every card was drawn 45% taller
    /// than the window it stands for, so the phone's picture of the desk did not
    /// match the desk.
    ///
    /// True aspect in both branches now. A wide desk genuinely is a short band
    /// on a portrait phone; the fix for that is the arrange modes (`gridFrame`),
    /// which lay cards out on the phone's terms instead of distorting the Mac's.
    static func hostScreenRect(in size: CGSize, aspect: CGFloat) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let available = size.width / size.height
        if available > aspect {
            let w = size.height * aspect
            return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: size.height)
        } else {
            let h = min(size.height, size.width / aspect)
            return CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
        }
    }

    /// Phone-only override frame for a window. Priority:
    ///   1. Per-window manual drag override (FR-16) — wins over everything.
    ///   2. Auto-arrange mode (`phoneLayoutOverride` set by chooser or
    ///      cycle button) — clean grid laid out via `gridFrame`.
    ///   3. `nil` → caller falls back to the Mac's real frame.
    private func phoneLayoutFrame(for window: WindowState, index: Int, total: Int) -> WindowFrame? {
        if let manual = phoneFrameOverrides[window.id] { return manual }
        guard let mode = phoneLayoutOverride, total > 0 else { return nil }
        return Self.gridFrame(mode: mode, index: index, total: total)
    }

    /// Grid cell for a given mode + position. Pure fn for unit tests
    /// (PhoneLayoutChooserTests). Returns `nil` for unknown modes so callers
    /// can fall through to the Mac frame.
    static func gridFrame(mode: String, index: Int, total: Int) -> WindowFrame? {
        guard total > 0, index >= 0, index < total else { return nil }
        switch mode {
        case "horizontal":
            let w = 1.0 / Double(total)
            return WindowFrame(x: Double(index) * w, y: 0, width: w, height: 1.0)
        case "vertical":
            let h = 1.0 / Double(total)
            return WindowFrame(x: 0, y: Double(index) * h, width: 1.0, height: h)
        case "grid":
            // Packed grid — `cols = ceil(sqrt(total))` keeps the layout
            // close to square, then rows = ceil(total/cols) fits the rest.
            // For total=4 → 2×2, total=5-6 → 3×2, total=7-9 → 3×3, total=10-12 → 4×3.
            // Last row's leftover cells stay empty (no row-padding hack) so cells
            // keep a uniform aspect — matches the user's reading model better
            // than centering a half-row.
            let cols = max(1, Int(Double(total).squareRoot().rounded(.up)))
            let rows = max(1, Int((Double(total) / Double(cols)).rounded(.up)))
            let row = index / cols
            let col = index % cols
            let w = 1.0 / Double(cols)
            let h = 1.0 / Double(rows)
            return WindowFrame(x: Double(col) * w, y: Double(row) * h, width: w, height: h)
        default:
            return nil
        }
    }

    /// Auto-arrange chooser. Pure fn — picks layout based on count:
    /// 1-2 windows → `"horizontal"` (side-by-side reads naturally on phone);
    /// 3 windows → `"vertical"` (stacked rows fit before grid is needed);
    /// 4+ windows → `"grid"` (2-or-3 column packed grid; vertical strips
    /// at 4+ get too narrow to read).
    static func chooseAutoLayout(count: Int) -> String {
        switch count {
        case ...2: return "horizontal"
        case 3:    return "vertical"
        default:   return "grid"
        }
    }

    /// Re-fire the auto-chooser given the current windows count. Called from
    /// `onLayoutUpdate` and from the Realign button. Skips when the user has
    /// engaged the manual-sticky flag UNLESS `force` is true (Realign path).
    private func runAutoChooser(count: Int, force: Bool = false) {
        guard count > 0 else { return }
        if !force && manualLayoutSticky { return }
        // Don't re-pick if neither the count nor the mode would change —
        // avoids needless @AppStorage writes on every windows-list arrival.
        if !force && count == lastChooserCount { return }
        let pick = Self.chooseAutoLayout(count: count)
        if phoneLayoutOverrideRaw != pick {
            phoneLayoutOverrideRaw = pick
        }
        lastChooserCount = count
    }

    /// Realign button action — wipes manual drag overrides, clears the
    /// sticky flag so the chooser is allowed to fire again, and re-runs
    /// the chooser immediately so the user sees the auto layout right away.
    private func realignWindows() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            phoneFrameOverrides = [:]
            persistOverrides()
            manualLayoutSticky = false
            lastChooserCount = -1
            runAutoChooser(count: windows.count, force: true)
        }
    }

    /// Re-encode `phoneFrameOverrides` into JSON and write to @AppStorage.
    /// Called after every mutation so a force-quit doesn't lose drag work.
    private func persistOverrides() {
        do {
            let data = try JSONEncoder().encode(phoneFrameOverrides)
            guard let json = String(data: data, encoding: .utf8) else {
                print("[Quip][Layout] persistOverrides FAILED: UTF-8 conversion — drag positions NOT saved")
                return
            }
            phoneFrameOverridesJSON = json
        } catch {
            print("[Quip][Layout] persistOverrides FAILED count=\(phoneFrameOverrides.count) err=\(error) — drag positions NOT saved")
        }
    }

    /// Decode the persisted override JSON into the in-memory dictionary.
    /// Called on view appear so a returning user sees their last positions
    /// before the first windows-list arrives — no flash of unstyled layout.
    private func loadOverrides() {
        guard !phoneFrameOverridesJSON.isEmpty else { return }   // fresh install
        guard let data = phoneFrameOverridesJSON.data(using: .utf8) else { return }
        do {
            phoneFrameOverrides = try JSONDecoder().decode([String: WindowFrame].self, from: data)
        } catch {
            print("[Quip][Layout] loadOverrides FAILED bytes=\(data.count) err=\(error) — saved window positions lost")
        }
    }

    /// Drop closed windows from the override dictionary so it doesn't grow
    /// forever. Called from `onLayoutUpdate` whenever the list arrives.
    private func pruneOverrides(activeWindowIds: Set<String>) {
        let filtered = phoneFrameOverrides.filter { activeWindowIds.contains($0.key) }
        if filtered.count != phoneFrameOverrides.count {
            phoneFrameOverrides = filtered
            persistOverrides()
        }
    }

    /// Drag-end handler. `dropCenter` is the dropped card's center in
    /// normalized 0–1 coordinates within the host-screen rect. REORDER model:
    /// the dragged card lands in the grid slot nearest the drop point and every
    /// other card reflows around it, with the new sequence persisted to
    /// `phoneWindowOrder` so it survives Mac layout-updates. Any legacy
    /// free-position frame overrides are cleared so all cards follow the grid
    /// in the new order.
    private func handleDrop(windowId: String, dropCenter: CGPoint) {
        let total = displayWindows.count
        guard total > 0 else { return }
        let mode = phoneLayoutOverride ?? Self.chooseAutoLayout(count: total)
        let slot = Self.nearestGridIndex(mode: mode, total: total, dropCenter: dropCenter)

        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
            // Reorder uses the index-based auto-grid; drop any per-window frame
            // overrides so cards aren't pinned to stale free positions, and let
            // the chooser keep picking the right mode for the count.
            if !phoneFrameOverrides.isEmpty {
                phoneFrameOverrides = [:]
                persistOverrides()
            }
            manualLayoutSticky = false
            reorderWindow(windowId, toSlot: slot)
        }
    }

    /// Move `windowId` to `targetSlot` in the persisted phone order so the grid
    /// reflows the dragged card into that position. Works against the CURRENT
    /// display order (what the user sees) so the slot math lines up with the
    /// rendered grid; remove-then-insert lands the card at the visual slot.
    private func reorderWindow(_ windowId: String, toSlot targetSlot: Int) {
        let current = displayWindows.map(\.id)
        let next = Self.reorderedSequence(current, moving: windowId, toSlot: targetSlot)
        guard next != current else { return }
        phoneWindowOrder = next
        persistWindowOrder()
    }

    /// Pure move: `order` with `id` pulled from its current position and
    /// reinserted at `slot` (clamped to a valid index). Returns the input
    /// unchanged when `id` is absent or already at `slot`. Extracted as a pure
    /// fn so the remove-then-insert clamp is unit-testable without a SwiftUI
    /// view (PhoneLayoutChooserTests).
    static func reorderedSequence(_ order: [String], moving id: String, toSlot slot: Int) -> [String] {
        guard let from = order.firstIndex(of: id) else { return order }
        let clamped = max(0, min(order.count - 1, slot))
        guard clamped != from else { return order }
        var next = order
        let moved = next.remove(at: from)
        next.insert(moved, at: clamped)
        return next
    }

    /// Decode the persisted phone window order on appear so a returning user's
    /// arrangement is in place before the first layout-update arrives.
    private func loadWindowOrder() {
        guard !phoneWindowOrderJSON.isEmpty else { return }   // fresh install
        guard let data = phoneWindowOrderJSON.data(using: .utf8) else { return }
        let decoded: [String]
        do {
            decoded = try JSONDecoder().decode([String].self, from: data)
        } catch {
            print("[Quip][Layout] loadWindowOrder FAILED bytes=\(data.count) err=\(error) — saved card order lost")
            return
        }
        phoneWindowOrder = decoded
        // Migration: a user upgrading from the old free-position drag model has
        // per-window frame overrides saved. Those win in phoneLayoutFrame and
        // would shadow the reorder grid until the first drop clears them. If a
        // saved reorder order already exists, the grid is authoritative now —
        // drop the legacy overrides up front so cards render in order from
        // launch instead of at stale free positions. (loadOverrides() runs
        // just before this in onAppear, so phoneFrameOverrides is populated.)
        if !decoded.isEmpty && !phoneFrameOverrides.isEmpty {
            phoneFrameOverrides = [:]
            persistOverrides()
        }
    }

    /// Re-encode `phoneWindowOrder` to @AppStorage after every mutation.
    private func persistWindowOrder() {
        do {
            let data = try JSONEncoder().encode(phoneWindowOrder)
            guard let json = String(data: data, encoding: .utf8) else {
                print("[Quip][Layout] persistWindowOrder FAILED: UTF-8 conversion — card order NOT saved")
                return
            }
            phoneWindowOrderJSON = json
        } catch {
            print("[Quip][Layout] persistWindowOrder FAILED count=\(phoneWindowOrder.count) err=\(error) — card order NOT saved")
        }
    }

    /// Keep the saved order in step with the live window set: append new ids
    /// (preserving incoming order) and drop closed ones. Called from
    /// `.onChange(of: windows)`. Only writes when the order actually changes,
    /// so it doesn't thrash @AppStorage on every layout-update.
    private func reconcileWindowOrder(activeWindows: [WindowState]) {
        let next = Self.reconciledWindowOrder(saved: phoneWindowOrder,
                                              active: activeWindows.map(\.id))
        if next != phoneWindowOrder {
            phoneWindowOrder = next
            persistWindowOrder()
        }
    }

    /// Pure reconcile: keep saved ids that are still active (in saved order),
    /// then append active ids not yet present (in incoming order). Drops closed
    /// windows; each id appears at most once. Extracted as a pure fn so the
    /// append/prune logic is unit-testable without a view.
    static func reconciledWindowOrder(saved: [String], active: [String]) -> [String] {
        let activeSet = Set(active)
        var next = saved.filter { activeSet.contains($0) }
        var seen = Set(next)
        for id in active where seen.insert(id).inserted { next.append(id) }
        return next
    }

    /// Pure-fn nearest-cell finder for snap-to-grid. Returns the index whose
    /// `gridFrame` center is closest to `dropCenter` in normalized space.
    static func nearestGridIndex(mode: String, total: Int, dropCenter: CGPoint) -> Int {
        var bestIdx = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for i in 0..<total {
            guard let cell = gridFrame(mode: mode, index: i, total: total) else { continue }
            let cx = CGFloat(cell.x + cell.width / 2)
            let cy = CGFloat(cell.y + cell.height / 2)
            let d = hypot(cx - dropCenter.x, cy - dropCenter.y)
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        return bestIdx
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
        // Same pin check as the real connection, so a probe never passes a
        // tunnel URL that the connection would then refuse (GH #10).
        let session = URLSession(configuration: .ephemeral,
                                 delegate: CloudflareCertificatePinningDelegate(),
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }
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

    /// Apply a decoded pairing payload: stage the backend URL, upsert the
    /// backend row, pre-stage its PIN in Keychain under the synthetic id,
    /// make it active, then connect. The single pairing entry point — shared
    /// by the in-app QR scanner sheet and the `quip://pair` deep link (via the
    /// `.quipApplyPairing` notification) so the pairing logic isn't duplicated.
    private func applyPairingPayload(_ payload: PairingPayload) {
        urlText = payload.url
        if let id = manager.addPaired(url: payload.url, name: "Backend") {
            KeychainBackendPINs.write(backendID: id, pin: payload.pin)
            manager.setActive(id)
        }
        doConnect()
    }

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
                connectToBackendURL(url)
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

    /// Upsert the backend row, then connect through the newly active session.
    /// `ensureImplicitDefault` may switch `manager.activeBackendID`; using the
    /// pre-switch `client` binding here dials the wrong WebSocketClient.
    private func connectToBackendURL(_ url: URL) {
        manager.ensureImplicitDefault(url: url.absoluteString)
        manager.active.client.connect(to: url)
    }

    // MARK: - Recent Connections

    /// Discovered Bonjour hosts worth offering: Macs with no paired row, and
    /// paired Macs whose row is not connected right now (US-012), so a Mac
    /// Bonjour can see is always one tap away even when its row's saved URLs
    /// are dead. A host whose TXT deviceID matches a paired row is also
    /// folded into that row (see the .onChange above), and tapping it
    /// reconnects that row rather than adding a second backend.
    private var newDiscoveredHosts: [DiscoveredHost] {
        DiscoveredHostFilter.visible(hosts: bonjourBrowser.discoveredHosts,
                                     paired: manager.paired,
                                     connectedBackendIDs: manager.connectedBackendIDs)
    }

    private func loadRecents() {
        guard !recentConnectionsData.isEmpty else { return }   // fresh install
        do {
            recentConnections = try JSONDecoder().decode([SavedConnection].self, from: recentConnectionsData)
        } catch {
            print("[Quip][Connections] loadRecents FAILED bytes=\(recentConnectionsData.count) err=\(error) — recent connection list lost")
        }
    }

    private func saveRecents() {
        do {
            recentConnectionsData = try JSONEncoder().encode(recentConnections)
        } catch {
            print("[Quip][Connections] saveRecents FAILED count=\(recentConnections.count) err=\(error) — recent connections NOT persisted")
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
        if case .setColor(let hex) = action {
            client.send(SetColorMessage(windowId: windowId, color: hex))
            return
        }
        if action == .viewOutput {
            onRequestContent(windowId)
            return
        }
        // Duplicate and closeWindow send different message types than
        // QuickActionMessage, so they're early-return branches.
        if action == .duplicate {
            client.send(DuplicateWindowMessage(sourceWindowId: windowId, agent: duplicateSpawnAgent(for: windowId)))
            return
        }
        if action == .closeWindow {
            client.send(CloseWindowMessage(windowId: windowId))
            return
        }
        if action == .minimize {
            client.send(MinimizeWindowMessage(windowId: windowId))
            return
        }
        if action == .restore {
            restoreMinimizedWindow(windowId)
            return
        }
        if action == .togglePin {
            // Ask for the opposite of what the last broadcast said. The Mac
            // answers with a fresh layout, so the card moves when the Mac has
            // actually written the pin, never before.
            let pinned = windows.first(where: { $0.id == windowId })?.isPinned ?? false
            if !pinned {
                // A pin means "put this first". Two things used to keep the
                // card where it was: a free-drag position saved for it (the
                // override wins over the grid cell) and a grid with no
                // arranged mode (cards sit where the Mac windows sit). Clear
                // the first, force the second (Q-58 follow-up).
                if phoneFrameOverrides.removeValue(forKey: windowId) != nil { persistOverrides() }
                if phoneLayoutOverride == nil {
                    phoneLayoutOverrideRaw = Self.chooseAutoLayout(count: max(windows.count, 1))
                    manualLayoutSticky = true
                }
            }
            client.send(SetPinMessage(windowId: windowId, pinned: !pinned))
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
        case .minimize, .restore: return // handled above
        case .togglePin: return   // handled above
        case .chooseColor:
            colorSheetWindowId = windowId
            return
        case .setColor: return   // handled above
        case .pairForQA:
            qaPickerSourceWindow = windowId
            showQAPicker = true
            return
        }
        client.send(QuickActionMessage(windowId: windowId, action: str))
    }

    private var selectedSpawnAgent: SpawnAgent {
        SpawnAgent(rawValue: spawnAgentRaw) ?? .claude
    }

    private func duplicateSpawnAgent(for windowId: String) -> SpawnAgent {
        guard let window = windows.first(where: { $0.id == windowId }) else {
            return selectedSpawnAgent
        }
        switch window.cliKind {
        case .claude:
            return .claude
        case .codex:
            return .codex
        case .grok:
            return .grok
        case .cursor:
            return .cursor
        case .shell:
            return .terminal
        case nil:
            return selectedSpawnAgent
        }
    }

    // MARK: - Configurable Quick Buttons

    /// Fire the wire action for a QuickButton — extracted from `quickActionButton`
    /// so the slash-letter Menu items (which trigger from a Menu, not a Button
    /// label) can share the same image-flush + send semantics.
    private func fireQuickButton(_ button: QuickButton) {
        // Needs no selected window: it opens a sheet with its own targets.
        if case .openBroadcast = button.action {
            fireBroadcastKey()
            return
        }
        guard let wid = selectedWindowId else { return }
        if button.isSlashCommand { recordSlashUsage(.builtin(button)) }
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
        case .openBroadcast:
            break
        }
    }

    /// Decoded custom-button definitions table. Read from JSON @AppStorage
    /// each call — cheap (single decode) and avoids stale snapshots when the
    /// editor mutates the table.
    private var customButtonDefs: [CustomButton] {
        CustomButtonStore.decode(customButtonsJSON)
    }

    /// The user's slot list with one-shot CSV→JSON migration handled in
    /// `.onAppear`. Custom slots whose definition was deleted out from
    /// under them are filtered out so the row doesn't render orphan pills.
    private var effectiveQuickSlots: [QuickSlot] {
        let raw = QuickSlotStore.decode(quickSlotsJSON)
        let validIds = Set(customButtonDefs.map(\.id))
        return raw.filter { slot in
            if case .custom(let id) = slot { return validIds.contains(id) }
            return true
        }
    }

    /// First letter after the leading "/" of a slash command (e.g. "c" for
    /// "/clear"). nil for non-slash entries or the bare "/".
    private func slashLetter(ofText text: String) -> Character? {
        guard text.count >= 2, text.first == "/" else { return nil }
        return text[text.index(after: text.startIndex)].lowercased().first
    }

    /// "/foo" prefix string for a built-in's slash command, or nil for
    /// non-slash. Wraps the QuickButton-specific check.
    private func slashLetter(of button: QuickButton) -> Character? {
        guard button.isSlashCommand, button != .slash else { return nil }
        return slashLetter(ofText: button.displayName)
    }

    /// First letter of a custom button's slash payload. nil if it's not a
    /// slash payload (raw text / keystroke customs don't get grouped).
    private func slashLetter(of custom: CustomButton) -> Character? {
        if case .slash(let text, _) = custom.payload {
            return slashLetter(ofText: text)
        }
        return nil
    }

    /// Member of a "/x…" group menu — either a built-in or a custom button.
    /// Identifiable so the Menu's ForEach has stable identity even when a
    /// group mixes the two kinds.
    enum SlashGroupMember: Identifiable {
        case builtin(QuickButton)
        case custom(CustomButton)

        var id: String {
            switch self {
            case .builtin(let b): return "b:\(b.rawValue)"
            case .custom(let c): return "c:\(c.id.uuidString)"
            }
        }

        var displayName: String {
            switch self {
            case .builtin(let b): return b.displayName
            case .custom(let c): return c.label
            }
        }

        /// The row slot this member came from, so the group menu can offer
        /// the same per-button actions a held pill gets.
        var slot: QuickSlot {
            switch self {
            case .builtin(let b): return .builtin(b)
            case .custom(let c): return .custom(c.id)
            }
        }
    }

    /// One renderable item in the slot row. Spacers carry their UUID so
    /// SwiftUI keeps stable identity when the user has multiple in a row.
    enum RowItem: Identifiable {
        case builtinButton(QuickButton)
        case customButton(CustomButton)
        case promptButton(promptID: String, label: String)
        /// Single "Prompts" pill that opens the library sheet (ranked by use).
        case promptsPicker
        case spacer(width: CGFloat, uid: UUID)
        case slashGroup(letter: Character, members: [SlashGroupMember])

        var id: String {
            switch self {
            case .builtinButton(let b): return "b:\(b.rawValue)"
            case .customButton(let c): return "c:\(c.id.uuidString)"
            case .promptButton(let pid, _): return "p:\(pid)"
            case .promptsPicker: return "pp"
            case .spacer(_, let uid): return "s:\(uid.uuidString)"
            case .slashGroup(let l, _): return "g:\(l)"
            }
        }
    }

    /// Walk the slot list and produce a render plan. Slash builtins and
    /// custom-slash buttons that share a first letter collapse into a single
    /// `.slashGroup` so the row stays compact when the user has many. Order
    /// preserved; only the first member of a multi-member letter emits the
    /// group pill.
    private func rowItems(_ slots: [QuickSlot], defs: [CustomButton]) -> [RowItem] {
        let defsById = Dictionary(uniqueKeysWithValues: defs.map { ($0.id, $0) })

        // Pre-pass: count slash-letter occurrences across builtins + customs
        // visible in this slot list, so we know which letters need grouping.
        var letterCount: [Character: Int] = [:]
        for slot in slots {
            switch slot {
            case .builtin(let b):
                if let key = slashLetter(of: b) { letterCount[key, default: 0] += 1 }
            case .custom(let id):
                if let c = defsById[id], let key = slashLetter(of: c) {
                    letterCount[key, default: 0] += 1
                }
            case .prompt, .promptsPicker, .spacer:
                break
            }
        }

        // Collect group members in slot-order so menu order matches the
        // user's row order.
        var members: [Character: [SlashGroupMember]] = [:]
        for slot in slots {
            switch slot {
            case .builtin(let b):
                if let key = slashLetter(of: b), (letterCount[key] ?? 0) > 1 {
                    members[key, default: []].append(.builtin(b))
                }
            case .custom(let id):
                if let c = defsById[id], let key = slashLetter(of: c), (letterCount[key] ?? 0) > 1 {
                    members[key, default: []].append(.custom(c))
                }
            case .prompt, .promptsPicker, .spacer:
                break
            }
        }

        var items: [RowItem] = []
        var emitted = Set<Character>()
        for slot in slots {
            switch slot {
            case .spacer(let uid):
                items.append(.spacer(width: 12, uid: uid))
            case .builtin(let b):
                if let key = slashLetter(of: b), let group = members[key], group.count > 1 {
                    if emitted.insert(key).inserted {
                        items.append(.slashGroup(letter: key, members: group))
                    }
                } else {
                    items.append(.builtinButton(b))
                }
            case .custom(let id):
                guard let c = defsById[id] else { continue }
                if let key = slashLetter(of: c), let group = members[key], group.count > 1 {
                    if emitted.insert(key).inserted {
                        items.append(.slashGroup(letter: key, members: group))
                    }
                } else {
                    items.append(.customButton(c))
                }
            case .prompt(let pid):
                // Look up the label from the live catalog. Fall back to the
                // id when the Mac hasn't broadcast yet — the pill stays
                // visible (greyed-out) so the slot order doesn't shift on
                // a brief disconnect. (§B3)
                let label = client.promptLibrary.first(where: { $0.id == pid })?.label ?? pid
                items.append(.promptButton(promptID: pid, label: label))
            case .promptsPicker:
                items.append(.promptsPicker)
            }
        }
        return items
    }

    /// Pill that matches `quickActionButton`'s shape but opens an iOS Menu
    /// when tapped. The Menu auto-positions to avoid overlapping the keys
    /// around it (system handles edge clipping + the dismiss-on-outside-tap),
    /// so the keyboard stays tidy until the user actually drills in.
    ///
    /// The group pill has no hold menu of its own (the Menu keeps its
    /// touches), so its members are edited from a "Change a Button" section
    /// here: one submenu per member with the held-pill actions (Q-67). Only
    /// the fire items need a selected window; editing works without one.
    @ViewBuilder
    private func slashGroupMenuButton(letter: Character, members: [SlashGroupMember]) -> some View {
        Menu {
            ForEach(members) { member in
                Button {
                    switch member {
                    case .builtin(let b): fireQuickButton(b)
                    case .custom(let c): fireCustomButton(c)
                    }
                } label: {
                    Text(member.displayName)
                }
                .disabled(selectedWindowId == nil)
            }
            Section("Change a Button") {
                ForEach(members) { member in
                    Menu(member.displayName) { quickMenuActions(member.slot) }
                }
            }
        } label: {
            KeyPill(spec: .slashGroup(letter: letter, auto: autoKeyStyle), enabled: selectedWindowId != nil)
        }
        .accessibilityHint(selectedWindowId == nil ? "Select a window to send; buttons can still be changed" : "")
    }

    /// Every slash command the user can reach from the long-press palette,
    /// most-used first (`SlashUsage`). Commands never fired keep the base
    /// order: all built-in slash `QuickButton`s (declaration order) followed
    /// by all custom `.slash` buttons (definition order). Deliberately INDEPENDENT of
    /// what's pinned in the row — the palette's whole purpose is to reach the
    /// slash commands the user didn't pin (vs. the `/x…` tap-menu, which only
    /// surfaces same-first-letter pills already on the row). Only commands
    /// for the selected window's agent, plus those for every agent (Q-72).
    private func allSlashMembers() -> [SlashGroupMember] {
        var members: [SlashGroupMember] = QuickButton.allCases
            .filter(\.isSlashCommand)
            .map { .builtin($0) }
        for c in customButtonDefs {
            if case .slash = c.payload { members.append(.custom(c)) }
        }
        let window = windows.first(where: { $0.id == selectedWindowId })?.cliKind
        return SlashUsage.ranked(SlashAgents.filter(members, window: window), id: \.id,
                                 store: promptUsageStore(), context: selectedPromptContext, at: Date())
    }

    /// Count one fire of a slash command so it climbs the palette, most of
    /// all in windows running the same agent as `windowID` (Q-73; nil: the
    /// selected window).
    private func recordSlashUsage(_ member: SlashGroupMember, in windowID: String? = nil) {
        let context = (windowID ?? selectedWindowId).flatMap(promptContext(forWindow:))
        promptUsageJSON = PromptRanker.encode(
            SlashUsage.recording(member.id, context: context, at: Date(), in: promptUsageStore())
        )
        if promptUsageMRUJSON != "{}" { promptUsageMRUJSON = "{}" }
    }

    /// Render the full slot row — built-ins, customs, spacers, and grouped
    /// `/x…` menus — in the user's chosen order.
    @ViewBuilder
    private func slotRowView(_ slots: [QuickSlot], space: String) -> some View {
        let items = rowItems(slots, defs: customButtonDefs)
        // Decoded once per row, not per pill: this body re-evaluates on every
        // terminal update.
        let tints = KeyColors.decode(quickSlotColorsJSON)
        // Q-65: every pill can be held and dragged to a new slot. Items are
        // the render plan (a slash group is one pill for several slots), so a
        // move re-emits the slot list from the new item order.
        let order = items.map(\.id)
        let slotsByItem = quickSlotsByItem(slots, items: items)
        ForEach(items) { item in
            Group {
                switch item {
                case .builtinButton(let b):
                    quickActionButton(b, tint: tints[QuickSlot.builtin(b).id])
                case .customButton(let c):
                    customQuickButton(c, tint: tints[QuickSlot.custom(c.id).id])
                case .promptButton(let pid, let label):
                    promptQuickButton(promptID: pid, label: label, tint: tints[QuickSlot.prompt(promptID: pid).id])
                case .promptsPicker:
                    promptsPickerButton(tint: tints[QuickSlot.promptsPicker.id])
                case .spacer(let w, _):
                    // Clear, but as tall as a pill so the gap can be held
                    // (menu) or dragged; a bare Spacer has no height to touch.
                    Color.clear.frame(width: w, height: 28)
                        .accessibilityElement()
                        .accessibilityLabel("Spacer")
                case .slashGroup(let letter, let members):
                    slashGroupMenuButton(letter: letter, members: members)
                }
            }
            // US-212: VoiceOver cannot hold a pill still, so the hold menu's
            // items are also named actions (a slash group's members carry
            // theirs inside its Menu).
            .accessibilityActions {
                if let slot = quickSlot(for: item) { quickMenuAccessibilityActions(slot) }
            }
            .modifier(QuickRowItemGesture(
                item: item, state: quickReorder, space: space, order: order,
                tap: quickRowTapAction(item), hold: quickRowHoldAction(item),
                onMove: { id, index in
                    let newOrder = RowReorderMath.move(order, id: id, to: index)
                    quickSlotsJSON = QuickSlotStore.encode(newOrder.flatMap { slotsByItem[$0] ?? [] })
                }))
        }
    }

    /// Applies the hold-and-drag gesture to every quick pill except a slash
    /// group, whose pill is a Menu that must keep its own touches.
    private struct QuickRowItemGesture: ViewModifier {
        let item: RowItem
        let state: RowReorderState
        let space: String
        let order: [String]
        let tap: (() -> Void)?
        let hold: (() -> Void)?
        let onMove: (String, Int) -> Void

        func body(content: Content) -> some View {
            if case .slashGroup = item {
                content
            } else {
                content.rowReorderItem(item.id, state: state, space: space, order: order,
                                       tap: tap, hold: hold, exclusive: false, onMove: onMove)
            }
        }
    }

    /// What a tap does on a quick pill, nil when the pill is disabled. The
    /// Button inside keeps the same action for VoiceOver.
    private func quickRowTapAction(_ item: RowItem) -> (() -> Void)? {
        switch item {
        case .builtinButton(let b):
            let enabled = b == .broadcast ? broadcastUnavailableReason == nil : selectedWindowId != nil
            return enabled || b == .broadcast ? { fireQuickButton(b) } : nil
        case .customButton(let c):
            return selectedWindowId != nil ? { fireCustomButton(c) } : nil
        case .promptButton(let pid, _):
            return { firePromptSlot(promptID: pid, pressReturn: false) }
        case .promptsPicker:
            let canFire = client.isConnected && !client.promptLibrary.isEmpty && selectedWindowId != nil
            return canFire ? { showPromptsPickerSheet = true } : nil
        case .spacer, .slashGroup:
            return nil
        }
    }

    /// The slots each rendered item stands for, so a reorder of items can be
    /// written back as a slot list. A slash group owns every slot that shares
    /// its letter, in their current order.
    private func quickSlotsByItem(_ slots: [QuickSlot], items: [RowItem]) -> [String: [QuickSlot]] {
        let defsById = Dictionary(uniqueKeysWithValues: customButtonDefs.map { ($0.id, $0) })
        var out: [String: [QuickSlot]] = [:]
        for item in items {
            switch item {
            case .builtinButton(let b): out[item.id] = [.builtin(b)]
            case .customButton(let c): out[item.id] = [.custom(c.id)]
            case .promptButton(let pid, _): out[item.id] = [.prompt(promptID: pid)]
            case .promptsPicker: out[item.id] = [.promptsPicker]
            case .spacer(_, let uid): out[item.id] = [.spacer(uid)]
            case .slashGroup(let letter, _):
                out[item.id] = slots.filter { slot in
                    switch slot {
                    case .builtin(let b): return slashLetter(of: b) == letter
                    case .custom(let id): return defsById[id].flatMap { slashLetter(of: $0) } == letter
                    default: return false
                    }
                }
            }
        }
        return out
    }

    /// What a hold-without-drag does on a quick pill: opens the button's menu
    /// (Q-67). The prompt pill's paste-and-submit and the slash pills'
    /// palette, which used to be the hold itself, are items in that menu.
    private func quickRowHoldAction(_ item: RowItem) -> (() -> Void)? {
        guard let slot = quickSlot(for: item) else { return nil }
        return { quickMenuSlot = slot }
    }

    /// The single slot a rendered pill stands for; nil for slash groups,
    /// whose pill is a Menu with no hold.
    private func quickSlot(for item: RowItem) -> QuickSlot? {
        switch item {
        case .builtinButton(let b): return .builtin(b)
        case .customButton(let c): return .custom(c.id)
        case .promptButton(let pid, _): return .prompt(promptID: pid)
        case .promptsPicker: return .promptsPicker
        case .spacer(_, let uid): return .spacer(uid)
        case .slashGroup: return nil
        }
    }

    private func quickSlotTitle(_ slot: QuickSlot) -> String {
        switch slot {
        case .builtin(let b): return b.displayName
        case .custom(let id): return customButtonDefs.first { $0.id == id }?.label ?? "Button"
        case .prompt(let pid): return client.promptLibrary.first { $0.id == pid }?.label ?? pid
        case .promptsPicker: return "Prompts"
        case .spacer: return "Spacer"
        }
    }

    /// Names the automatic color a reset goes back to (Q-50, US-204).
    private func quickSlotColorResetLabel(_ slot: QuickSlot) -> String {
        let customs = Dictionary(customButtonDefs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let automatic = KeyPillSpec.slot(slot, auto: autoKeyStyle, userColor: nil, customs: customs,
                                         promptLabel: { quickSlotTitle(.prompt(promptID: $0)) },
                                         symbolExists: KeySymbol.exists)
        return KeyPillSpec.colorResetLabel(automatic: automatic, auto: autoKeyStyle)
    }

    private func isSlashSlot(_ slot: QuickSlot) -> Bool {
        switch slot {
        case .builtin(let b): return b.isSlashCommand
        case .custom(let id):
            if case .slash = customButtonDefs.first(where: { $0.id == id })?.payload { return true }
            return false
        default: return false
        }
    }

    /// A spacer is an empty gap; it has nothing to color or edit.
    private func isSpacerSlot(_ slot: QuickSlot) -> Bool {
        if case .spacer = slot { return true }
        return false
    }

    /// Q-67: the menu a held keyboard button shows. Built from
    /// `QuickMenu.items`, the same list VoiceOver's Actions get (US-212).
    @ViewBuilder
    private func quickMenuActions(_ slot: QuickSlot) -> some View {
        ForEach(QuickMenu.items(quickMenuFacts(slot))) { item in
            Button(item.title, role: item.isDestructive ? .destructive : nil) {
                performQuickMenuItem(item, on: slot)
            }
        }
    }

    /// Q-51 US-212: every hold-menu item as a named VoiceOver action, so the
    /// Actions rotor reaches what a held pill offers.
    @ViewBuilder
    private func quickMenuAccessibilityActions(_ slot: QuickSlot) -> some View {
        ForEach(QuickMenu.items(quickMenuFacts(slot))) { item in
            Button(item.title) { performQuickMenuItem(item, on: slot) }
        }
    }

    private func quickMenuFacts(_ slot: QuickSlot) -> QuickMenu.Facts {
        var facts = QuickMenu.Facts()
        if case .prompt = slot { facts.isPrompt = true }
        facts.isSlash = isSlashSlot(slot)
        facts.isSpacer = isSpacerSlot(slot)
        facts.canSendTo = QuickSend.action(for: slot, defs: customButtonDefs) != nil
        let editsButton = QuickButtonEdit.editable(slot, defs: customButtonDefs) != nil
        facts.canEdit = editsButton || quickMenuPromptEntry(slot) != nil
        facts.editIncludesColor = editsButton
        return facts
    }

    /// The library entry a prompt slot edits, when the Mac has sent it.
    private func quickMenuPromptEntry(_ slot: QuickSlot) -> PromptEntry? {
        guard case .prompt(let pid) = slot else { return nil }
        return client.promptLibrary.first(where: { $0.id == pid })
    }

    private func performQuickMenuItem(_ item: QuickMenuItem, on slot: QuickSlot) {
        switch item {
        case .pasteAndSend:
            if case .prompt(let pid) = slot { firePromptSlot(promptID: pid, pressReturn: true) }
        case .allSlashCommands:
            // One dialog can't open while another is still animating away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showSlashPalette = true }
        case .sendTo:
            sendToSlot = slot
        case .edit:
            if QuickButtonEdit.editable(slot, defs: customButtonDefs) != nil {
                editingQuickSlot = slot
            } else if let entry = quickMenuPromptEntry(slot) {
                editingQuickPrompt = entry
            }
        case .color:
            coloringQuickSlot = slot
        case .addSpacerAfter:
            quickSlotsJSON = QuickSlotStore.encode(QuickButtonEdit.addingSpacer(after: slot, in: effectiveQuickSlots))
        case .remove:
            removeQuickSlot(slot)
        }
    }

    /// Removes a slot from the row and offers Undo for 8 s.
    private func removeQuickSlot(_ slot: QuickSlot) {
        let slots = effectiveQuickSlots
        guard let index = slots.firstIndex(of: slot) else { return }
        quickSlotsJSON = QuickSlotStore.encode(QuickButtonEdit.removing(slot, from: slots))
        showRowNote("Removed \(quickSlotTitle(slot))") {
            quickSlotsJSON = QuickSlotStore.encode(QuickButtonEdit.restoring(slot, at: index, in: effectiveQuickSlots))
        }
    }

    /// Q-51 / US-209: Pin to Row puts a slash command at the end of the row,
    /// Remove from Row takes it out; both offer Undo.
    private func toggleQuickSlotPin(_ slot: QuickSlot) {
        let slots = effectiveQuickSlots
        if slots.contains(slot) {
            removeQuickSlot(slot)
            return
        }
        quickSlotsJSON = QuickSlotStore.encode(QuickButtonEdit.restoring(slot, at: slots.count, in: slots))
        showRowNote("Pinned \(quickSlotTitle(slot)) to the row") {
            quickSlotsJSON = QuickSlotStore.encode(QuickButtonEdit.removing(slot, from: effectiveQuickSlots))
        }
    }

    /// Q-51: a button's action aimed at `windowID` instead of the selected
    /// window, which stays selected. A pending photo is not attached: it was
    /// meant for the selected window and stays queued for it.
    private func sendQuick(_ action: QuickSend, slot: QuickSlot, to windowID: String) {
        let sent: Bool
        switch action {
        case .text(let text, let pressReturn):
            sent = client.send(SendTextMessage(windowId: windowID, text: text, pressReturn: pressReturn))
        case .keystroke(let key):
            sent = client.send(QuickActionMessage(windowId: windowID, action: key))
        case .prompt(let id, let pressReturn):
            sent = client.send(PastePromptMessage(id: id, windowId: windowID, pressReturn: pressReturn))
            if sent { recordPromptUsage(id, context: promptContext(forWindow: windowID)) }
        }
        if sent, isSlashSlot(slot) {
            switch slot {
            case .builtin(let b): recordSlashUsage(.builtin(b), in: windowID)
            case .custom(let id):
                if let def = customButtonDefs.first(where: { $0.id == id }) {
                    recordSlashUsage(.custom(def), in: windowID)
                }
            default: break
            }
        }
        let name = windows.first { $0.id == windowID }?.displayTitle ?? "window"
        showRowNote(sent ? "Sent to \(name)" : "Not sent: not connected")
    }

    private struct RowNote {
        let id = UUID()
        let text: String
        let undo: (() -> Void)?
    }

    private func showRowNote(_ text: String, undo: (() -> Void)? = nil) {
        let note = RowNote(text: text, undo: undo)
        rowNote = note
        rowNoteTask?.cancel()
        rowNoteTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(undo == nil ? 4 : 8))
            guard !Task.isCancelled, rowNote?.id == note.id else { return }
            rowNote = nil
        }
    }

    /// The whole capsule is the button, as with `broadcastResultLine`: Undo
    /// when the note offers it, otherwise it just dismisses.
    @ViewBuilder
    private var rowNoteLine: some View {
        if let note = rowNote {
            Button {
                note.undo?()
                rowNote = nil
            } label: {
                HStack(spacing: 12) {
                    Text(note.text)
                    if note.undo != nil {
                        Text("Undo")
                            .fontWeight(.semibold)
                            .foregroundStyle(.yellow)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.78))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint(note.undo == nil ? "Dismisses this message" : "Undoes it")
            .transition(toastTransition)
        }
    }

    /// Q-67: writes an edit made from the row's menu.
    private func saveQuickEdit(_ edited: CustomButton, over slot: QuickSlot) {
        let r = QuickButtonEdit.save(edited, over: slot, slots: effectiveQuickSlots, defs: customButtonDefs,
                                     colors: KeyColors.decode(quickSlotColorsJSON))
        customButtonsJSON = CustomButtonStore.encode(r.defs)
        quickSlotsJSON = QuickSlotStore.encode(r.slots)
        quickSlotColorsJSON = KeyColors.encode(r.colors)
    }

    /// Pill rendering + tap handling for a Mac-managed prompt slot.
    /// Style mirrors `customQuickButton` but uses the SF Symbol for
    /// "doc.text" + a purple tint so the user can tell library-prompts
    /// apart from custom-text buttons. Tap fires PastePromptMessage to
    /// the active window; long-press paste-and-submits. Disabled when
    /// the Mac hasn't broadcast its catalog (label = id) so a stale
    /// slot doesn't fire to a window with nothing to paste. (§B3)
    @ViewBuilder
    private func promptQuickButton(promptID: String, label: String, tint: String? = nil) -> some View {
        let entry = client.promptLibrary.first(where: { $0.id == promptID })
        let canFire = entry != nil && client.isConnected && selectedWindowId != nil
        Button {
            firePromptSlot(promptID: promptID, pressReturn: false)
        } label: {
            KeyPill(spec: .prompt(label: label, auto: autoKeyStyle, userColor: tint), enabled: canFire)
        }
        .buttonStyle(.plain)
        .disabled(!canFire)
        .accessibilityLabel("Prompt: \(label)")
        .accessibilityHint(canFire ? "Tap to paste. Hold or use Actions for more; hold and drag to move" : "Prompt unavailable")
        .accessibilityAddTraits(.isButton)
        // The hold-and-release menu (with Paste & Send) lives in the row's
        // reorder modifier (quickRowHoldAction), which owns the long press
        // (Q-65, Q-67).
    }

    private func firePromptSlot(promptID: String, pressReturn: Bool) {
        guard let wid = selectedWindowId, !wid.isEmpty else { return }
        client.send(PastePromptMessage(id: promptID, windowId: wid, pressReturn: pressReturn))
        recordPromptUsage(promptID, context: selectedPromptContext)
    }

    /// Single "Prompts" pill — opens a sheet listing every prompt in the
    /// Mac catalog, ranked by use (`PromptRanker`). Replaces stuffing per-prompt
    /// `.prompt(id)` slots into the keyboard row when the user has more
    /// prompts than reasonably fit.
    @ViewBuilder
    private func promptsPickerButton(tint: String? = nil) -> some View {
        let canFire = client.isConnected && !client.promptLibrary.isEmpty && selectedWindowId != nil
        Button {
            showPromptsPickerSheet = true
        } label: {
            KeyPill(spec: .promptsPicker(userColor: tint), enabled: canFire)
        }
        .buttonStyle(.plain)
        .disabled(!canFire)
        .accessibilityLabel("Prompts library")
        .accessibilityHint(canFire ? "Open prompt picker" : "No prompts available")
        .accessibilityAddTraits(.isButton)
        // Sheet is hoisted to MainiOSView.body (`promptsPickerSheet` modifier)
        // so the main-row Prompts button can also present it when this slot
        // pill isn't placed in the Quick Buttons row.
    }

    /// The selected window's project: which project's prompts the selector
    /// lists (Q-69). The Mac's `project` (git root, so a window in `demo-proj/src`
    /// is `demo-proj`) wins; an older Mac sends only the folder. Nil with no
    /// window selected or neither.
    private var selectedProject: String? {
        let window = windows.first(where: { $0.id == selectedWindowId })
        for name in [window?.project, window?.folder] {
            if let name, !name.isEmpty { return name }
        }
        return nil
    }

    /// The agent running in the selected window, as a ranking context.
    private var selectedPromptContext: String? {
        selectedWindowId.flatMap(promptContext(forWindow:))
    }

    /// The agent running in a window, as a ranking context.
    private func promptContext(forWindow windowID: String) -> String? {
        guard let window = windows.first(where: { $0.id == windowID }) else { return nil }
        return (window.cliKind ?? .shell).rawValue
    }

    /// Current usage store, seeded once from the legacy last-use map so an
    /// upgrade keeps the order the user already had.
    private func promptUsageStore() -> PromptRanker.Store {
        PromptRanker.load(usageJSON: promptUsageJSON, legacyMRUJSON: promptUsageMRUJSON)
    }

    /// Count one fire of `promptID` in `context`, so it climbs the picker.
    private func recordPromptUsage(_ promptID: String, context: String?) {
        promptUsageJSON = PromptRanker.encode(
            PromptRanker.recording(promptID, context: context, at: Date(), in: promptUsageStore())
        )
        if promptUsageMRUJSON != "{}" { promptUsageMRUJSON = "{}" }
    }

    /// Wire-side dispatch for a custom button. Mirrors `fireQuickButton` so
    /// image-flush + auto-submit semantics stay identical between built-ins
    /// and customs.
    private func fireCustomButton(_ btn: CustomButton) {
        guard let wid = selectedWindowId else { return }
        switch btn.payload {
        case .slash(let text, let auto):
            recordSlashUsage(.custom(btn))
            sendCustomText(text, autoSubmit: auto, windowId: wid)
        case .rawText(let text, let auto):
            sendCustomText(text, autoSubmit: auto, windowId: wid)
        case .keystroke(let action):
            if action == "press_return" {
                sendPendingImageIfNeeded(windowId: wid) { [client] in
                    client.send(QuickActionMessage(windowId: wid, action: action))
                }
            } else {
                client.send(QuickActionMessage(windowId: wid, action: action))
            }
        }
    }

    /// Shared text-send helper for custom slash + raw-text payloads. Auto-
    /// submitting payloads flush the pending image first so the Mac
    /// processes attachments before the prompt — same race rule as the
    /// built-in slash buttons.
    private func sendCustomText(_ text: String, autoSubmit: Bool, windowId wid: String) {
        if autoSubmit {
            sendPendingImageIfNeeded(windowId: wid) { [client] in
                client.send(SendTextMessage(windowId: wid, text: text, pressReturn: autoSubmit))
            }
        } else {
            client.send(SendTextMessage(windowId: wid, text: text, pressReturn: autoSubmit))
        }
    }

    /// Pill rendering for a custom button. Uses the same outer chrome as
    /// `quickActionButton` so customs visually match built-ins.
    @ViewBuilder
    private func customQuickButton(_ btn: CustomButton, tint: String? = nil) -> some View {
        Button {
            fireCustomButton(btn)
        } label: {
            KeyPill(spec: .custom(btn, auto: autoKeyStyle, userColor: tint, symbolExists: KeySymbol.exists),
                    enabled: selectedWindowId != nil)
        }
        .disabled(selectedWindowId == nil)
        .accessibilityLabel(btn.label)
        .accessibilityHint(selectedWindowId == nil ? "No window selected" : "Custom shortcut")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func quickActionButton(_ button: QuickButton, tint: String? = nil) -> some View {
        // Broadcast needs no selected window, and stays tappable while it
        // cannot open so a tap can say why (US-113).
        let isBroadcast = button == .broadcast
        let isEnabled = isBroadcast ? broadcastUnavailableReason == nil : selectedWindowId != nil
        Button {
            fireQuickButton(button)
        } label: {
            // An icon-only pill draws the symbol alone, never a Text behind
            // it: a label wider than the 16x16 frame (e.g. "Ctrl+C") bled
            // past the icon and looked like a second pill nested inside.
            KeyPill(spec: .builtin(button, auto: autoKeyStyle, userColor: tint), enabled: isEnabled)
        }
        .disabled(!isBroadcast && selectedWindowId == nil)
        .accessibilityLabel(isBroadcast ? (broadcastUnavailableReason ?? button.displayName) : button.displayName)
        .accessibilityHint(isBroadcast ? "Choose terminal windows and send the same prompt to each one"
                           : selectedWindowId == nil ? "No window selected" : "Quick action")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - QR Scanner
