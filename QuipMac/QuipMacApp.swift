import SwiftUI

@main
struct QuipMacApp: App {
    @State private var windowManager = WindowManager()
    @State private var webSocketServer = WebSocketServer()
    @State private var bonjourAdvertiser = BonjourAdvertiser()
    @State private var terminalStateDetector = TerminalStateDetector()
    @State private var terminalColorManager = TerminalColorManager()
    @State private var keystrokeInjector = KeystrokeInjector()
    @State private var tunnel = CloudflareTunnel()
    @State private var tailscale = TailscaleService()
    @State private var pinManager = PINManager()
    @State private var connectionLog = ConnectionLog()
    @AppStorage("networkMode") private var networkModeRaw: String = NetworkMode.cloudflareTunnel.rawValue

    private var networkMode: NetworkMode {
        NetworkMode(rawValue: networkModeRaw) ?? .cloudflareTunnel
    }
    @State private var outputHighWaterMarks: [String: String] = [:]
    @State private var ttsGeneration: [String: Int] = [:]
    /// Windows where Claude is actively thinking (detected from terminal content)
    @State private var thinkingWindows: Set<String> = []
    /// Last window the phone client selected — only this one gets TTS synthesis
    @State private var clientSelectedWindowId: String? = nil
    /// Windows that must see a "busy" state (Claude processing) before the next
    /// waiting_for_input can fire TTS. Set when STT is received, cleared when
    /// we see Claude actually start processing. Prevents stale-response readback.
    @State private var pendingInputForWindow: Set<String> = []
    /// Terminal content snapshot at the moment STT was sent, per window.
    /// Used to verify Claude has actually written something new before firing TTS.
    @State private var sttBaselineContent: [String: String] = [:]
    /// Throttle request_content to at most once per 5 seconds per window.
    @State private var lastContentRequestTime: [String: Date] = [:]
    /// Last Claude response marker text we spoke per window. Used to dedupe
    /// repeated triggers where the raw terminal content changed slightly
    /// (cursor, prompt line) but the actual response is the same.
    @State private var lastSpokenMarker: [String: String] = [:]
    /// Per-window TTS session id. Persists across delta chunks within a single
    /// response turn so the phone queues them instead of cancelling earlier
    /// chunks. Cleared on new user input so the next response gets a fresh id,
    /// which does interrupt any leftover audio from the prior response.
    @State private var ttsSessionIds: [String: String] = [:]
    private let kokoroTTS = KokoroTTS()

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(windowManager)
                .environment(webSocketServer)
                .environment(bonjourAdvertiser)
                .environment(terminalStateDetector)
                .environment(terminalColorManager)
                .environment(keystrokeInjector)
                .environment(tunnel)
                .environment(tailscale)
                .onAppear { startServicesOnce() }
                .onChange(of: networkModeRaw) { _, _ in
                    applyNetworkMode()
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 960, height: 640)

        MenuBarExtra("Quip", systemImage: "waveform.circle.fill") {
            MenuBarView()
                .environment(windowManager)
                .environment(webSocketServer)
                .environment(bonjourAdvertiser)
                .environment(tunnel)
                .environment(tailscale)
                .onAppear { startServicesOnce() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(windowManager)
                .environment(webSocketServer)
                .environment(bonjourAdvertiser)
                .environment(tunnel)
                .environment(tailscale)
                .environment(pinManager)
                .environment(connectionLog)
        }
    }

    @State private var servicesStarted = false

    private func startServicesOnce() {
        guard !servicesStarted else { return }
        servicesStarted = true

        // One-time migration from legacy localOnlyMode bool to networkMode enum.
        // `migrateNetworkModeIfNeeded` writes directly to UserDefaults; @AppStorage
        // reads that value fresh on the next access. We intentionally do NOT
        // re-assign through `networkModeRaw` — that would risk firing the
        // `.onChange(of: networkModeRaw)` handler and double-calling
        // `applyNetworkMode()`. The explicit call below is the single source
        // of truth for initial-mode startup.
        _ = migrateNetworkModeIfNeeded()

        webSocketServer.pinManager = pinManager
        webSocketServer.connectionLog = connectionLog
        let requirePIN = UserDefaults.standard.bool(forKey: "requirePINForLocal")
        webSocketServer.requireAuth = requirePIN
        webSocketServer.start()

        // Apply current network mode (starts tunnel or Tailscale as needed).
        applyNetworkMode()

        // Small delay to let WebSocket listener reach .ready before advertising
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            bonjourAdvertiser.startAdvertising()
        }

        // Re-detect Tailscale whenever another app activates — cheap way to
        // pick up the case where the user opened the Tailscale app while Quip
        // was already running and hadn't yet logged in.
        // NOTE: NSWorkspace notifications post through its OWN notification
        // center, NOT `NotificationCenter.default`. Registering on `.default`
        // would silently no-op.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if networkMode == .tailscale {
                    tailscale.refresh()
                }
            }
        }

        webSocketServer.onMessageReceived = { [self] data in
            DispatchQueue.main.async {
                self.handleIncomingMessage(data)
            }
        }

        webSocketServer.onClientAuthenticated = { [self] in
            DispatchQueue.main.async {
                self.broadcastLayout()
            }
        }

        terminalStateDetector.onStateTransition = { [self] windowId, oldState, newState in
            webSocketServer.broadcast(StateChangeMessage(windowId: windowId, state: newState.rawValue))

            // Clear the pending-input flag as soon as we see Claude actually become busy.
            if newState == .neutral && pendingInputForWindow.contains(windowId) {
                pendingInputForWindow.remove(windowId)
                KokoroTTSDebug.log("pendingInput cleared for \(windowId) — Claude is processing")
            }

            if newState == .waitingForInput {
                thinkingWindows.remove(windowId)
                if pendingInputForWindow.contains(windowId) {
                    KokoroTTSDebug.log("TTS suppressed: \(windowId) still pending input response")
                    return
                }
                triggerTTSFor(windowId: windowId)
            }
        }

        terminalStateDetector.startMonitoring()
        windowManager.refreshDisplays()
        windowManager.refreshWindowList()
        syncTrackedWindows()

        // One-time Accessibility prompt at launch. Without this, the phone's
        // arrange button used to fire the dialog on every tap — Spammed until
        // the user granted or manually denied in System Settings.
        windowManager.promptForAccessibilityIfNeeded()

        // Pre-warm the Kokoro daemon so the first synth doesn't pay model load
        kokoroTTS.preload()

        var subtitleCounter = 0
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            // Read on main so we can use @MainActor state; the expensive
            // AppleScript/CG calls run off-main below.
            let forceSessionFetch = windowManager.needsIterm2SessionIdRefresh
            DispatchQueue.global(qos: .utility).async {
                let snapshot = WindowManager.fetchWindowList()
                subtitleCounter += 1
                let subtitles: [CGWindowID: String]?
                if subtitleCounter >= 5 {
                    subtitleCounter = 0
                    subtitles = WindowManager.fetchSubtitles()
                } else {
                    subtitles = nil
                }
                // Fetch session IDs on the subtitle cycle OR whenever the Mac
                // side has any iTerm2 window still missing a UUID. Without the
                // latter, a new window can route keystrokes to the wrong pane
                // for up to the full 10s subtitle-cycle gap.
                let shouldFetchSessions = subtitles != nil || forceSessionFetch
                let sessions = shouldFetchSessions ? WindowManager.fetchIterm2SessionIds() : nil
                DispatchQueue.main.async {
                    windowManager.applyWindowSnapshot(snapshot)
                    if let subtitles { windowManager.applySubtitles(subtitles) }
                    if let sessions { windowManager.applyIterm2SessionIds(sessions) }
                    self.syncTrackedWindows()
                    broadcastLayout()
                }
            }
        }
    }

    /// Switch between Cloudflare tunnel, Tailscale, and local-only based on
    /// the current `networkMode`. Safe to call repeatedly — each branch is
    /// idempotent on its own dependencies.
    @MainActor
    private func applyNetworkMode() {
        let requirePIN = UserDefaults.standard.bool(forKey: "requirePINForLocal")
        webSocketServer.requireAuth = requirePIN

        switch networkMode {
        case .cloudflareTunnel:
            tailscale.stop()
            tunnel.webSocketServer = webSocketServer
            tunnel.start()
        case .tailscale:
            tunnel.stop()
            tailscale.refresh()
        case .localOnly:
            tunnel.stop()
            tailscale.stop()
        }
    }

    /// Poll terminal content until it differs meaningfully from the STT baseline,
    /// indicating Claude has written a response. Fires TTS when detected, or times out.
    @MainActor
    private func schedulePendingInputResponseCheck(windowId: String, attempt: Int) {
        // Poll every 0.2s, give up after 300 attempts (60 seconds total)
        let maxAttempts = 300
        guard attempt < maxAttempts else {
            KokoroTTSDebug.log("pendingInput response check timed out for \(windowId)")
            pendingInputForWindow.remove(windowId)
            sttBaselineContent.removeValue(forKey: windowId)
            return
        }
        guard pendingInputForWindow.contains(windowId) else {
            // Flag was cleared by another path (state transition saw Claude go busy)
            return
        }

        // Grab what we need from main-actor state, then do the heavy
        // readContent call on a background thread so main stays responsive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard pendingInputForWindow.contains(windowId) else { return }
            guard let window = windowManager.windows.first(where: { $0.id == windowId }) else {
                schedulePendingInputResponseCheck(windowId: windowId, attempt: attempt + 1)
                return
            }
            let termApp = terminalAppForWindow(window)
            let wn = window.windowNumber
            let baseline = sttBaselineContent[windowId] ?? ""

            DispatchQueue.global(qos: .userInitiated).async { [keystrokeInjector] in
                let current = keystrokeInjector.readContent(terminalApp: termApp, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId) ?? ""
                let baselineLast = self.lastResponseMarkerText(in: baseline)
                let currentLast = self.lastResponseMarkerText(in: current)

                DispatchQueue.main.async { [self] in
                    guard pendingInputForWindow.contains(windowId) else { return }
                    let currentState = terminalStateDetector.windowStates[windowId] ?? .neutral

                    if attempt % 4 == 0 {
                        KokoroTTSDebug.log("poll[\(attempt)] \(windowId): lastMarker changed=\(baselineLast != currentLast), state=\(currentState.rawValue), content=\(current.count) bytes")
                    }

                    if baselineLast != currentLast && !currentLast.isEmpty && currentState == .waitingForInput {
                        KokoroTTSDebug.log("pendingInput: detected new response for \(windowId), firing TTS")
                        pendingInputForWindow.remove(windowId)
                        sttBaselineContent.removeValue(forKey: windowId)
                        triggerTTSFor(windowId: windowId, skipStableWait: true)
                    } else {
                        schedulePendingInputResponseCheck(windowId: windowId, attempt: attempt + 1)
                    }
                }
            }
        }
    }

    /// Return the text of the LAST Claude Code response marker (⏺ prose line),
    /// or empty string if none found. Used to detect when a new response has been added.
    private nonisolated func lastResponseMarkerText(in text: String) -> String {
        var lastText = ""
        for line in text.split(separator: "\n") {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            guard stripped.hasPrefix("⏺") else { continue }
            let rest = String(stripped.dropFirst()).trimmingCharacters(in: .whitespaces)
            if rest.range(of: #"^[A-Z][A-Za-z]*\("#, options: .regularExpression) != nil { continue }
            lastText = rest
        }
        return lastText
    }

    /// Read terminal content for the given window, compute delta, synthesize TTS audio,
    /// and stream chunks to connected clients. Called from state transitions and from
    /// the pendingInput polling path.
    /// `skipStableWait` bypasses the content-stability poll — use when caller has already
    /// verified the response is present (e.g. the pending-input polling path).
    @MainActor
    private func triggerTTSFor(windowId: String, skipStableWait: Bool = false) {
        guard let window = windowManager.windows.first(where: { $0.id == windowId }) else { return }
        let termApp = terminalAppForWindow(window)
        let wn = window.windowNumber
        let name = window.name

        let processContent: @Sendable (String) -> Void = { content in
            DispatchQueue.main.async { [self] in
                doTriggerTTSBody(windowId: windowId, name: name, content: content)
            }
        }

        if skipStableWait {
            DispatchQueue.global(qos: .userInitiated).async { [keystrokeInjector] in
                let content = keystrokeInjector.readContent(terminalApp: termApp, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId) ?? ""
                if !content.isEmpty {
                    processContent(content)
                }
            }
            return
        }

        waitForStableContent(termApp: termApp, windowNumber: wn, iterm2SessionId: window.iterm2SessionId) { stableContent in
            guard let content = stableContent else { return }
            DispatchQueue.main.async { [self] in
                doTriggerTTSBody(windowId: windowId, name: name, content: content)
            }
        }
    }

    @MainActor
    private func doTriggerTTSBody(windowId: String, name: String, content: String) {
            let delta = computeDelta(windowId: windowId, newContent: content)
            outputHighWaterMarks[windowId] = content
            guard !delta.isEmpty else { return }

            // Dedupe: if the last ⏺ response marker in the content matches
            // what we already spoke for this window, skip. Catches the case
            // where cursor/prompt changes cause a non-empty delta but the
            // actual Claude response is unchanged.
            let currentMarker = lastResponseMarkerText(in: content)
            if !currentMarker.isEmpty && lastSpokenMarker[windowId] == currentMarker {
                KokoroTTSDebug.log("doTriggerTTSBody skipped — marker unchanged for \(windowId)")
                return
            }
            lastSpokenMarker[windowId] = currentMarker

            webSocketServer.broadcast(OutputDeltaMessage(windowId: windowId, windowName: name, text: delta, isFinal: true))

            let gen = (ttsGeneration[windowId] ?? 0) + 1
            ttsGeneration[windowId] = gen

            let wid = windowId
            let wname = name
            let sessionId: String
            if let existing = ttsSessionIds[windowId] {
                sessionId = existing
            } else {
                sessionId = UUID().uuidString
                ttsSessionIds[windowId] = sessionId
            }
            var sequence = 0

            let checkStale: @Sendable () -> Bool = {
                var isLatest = false
                DispatchQueue.main.sync {
                    isLatest = (ttsGeneration[wid] ?? 0) == gen
                }
                return isLatest
            }

            kokoroTTS.synthesize(delta, shouldProceed: checkStale, onChunk: { [webSocketServer] wavChunk in
                DispatchQueue.main.async {
                    guard (ttsGeneration[wid] ?? 0) == gen else {
                        KokoroTTSDebug.log("DROPPED mid-stream chunk for stale gen=\(gen)")
                        return
                    }
                    let b64 = wavChunk.base64EncodedString()
                    webSocketServer.broadcast(TTSAudioMessage(
                        windowId: wid, windowName: wname,
                        sessionId: sessionId, sequence: sequence, isFinal: false,
                        audioBase64: b64
                    ))
                    KokoroTTSDebug.log("BROADCAST chunk \(sequence) session=\(sessionId.prefix(8)) \(b64.count) b64")
                    sequence += 1
                }
            }, onComplete: { [webSocketServer] in
                DispatchQueue.main.async {
                    guard (ttsGeneration[wid] ?? 0) == gen else { return }
                    webSocketServer.broadcast(TTSAudioMessage(
                        windowId: wid, windowName: wname,
                        sessionId: sessionId, sequence: sequence, isFinal: true,
                        audioBase64: ""
                    ))
                    KokoroTTSDebug.log("BROADCAST final marker session=\(sessionId.prefix(8))")
                }
            })
    }

    @MainActor
    private func broadcastLayout() {
        guard webSocketServer.hasConnectedClients else { return }
        let display = windowManager.displays.first(where: { $0.isMain }) ?? windowManager.displays.first
        let screenBounds = display?.frame ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let states = windowManager.windows.filter(\.isEnabled).map { window in
            window.toWindowState(
                state: terminalStateDetector.windowStates[window.id]?.rawValue ?? "neutral",
                screenBounds: screenBounds,
                isThinking: thinkingWindows.contains(window.id)
            )
        }
        let aspect = screenBounds.height > 0 ? Double(screenBounds.width / screenBounds.height) : nil
        let update = LayoutUpdate(monitor: display?.name ?? "Display 1", screenAspect: aspect, windows: states)
        webSocketServer.broadcast(update)
        broadcastProjectDirectories()
    }

    private func broadcastProjectDirectories() {
        let data = UserDefaults.standard.data(forKey: "projectDirectories") ?? Data()
        let roots = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        guard !roots.isEmpty else { return }
        // Expand each configured root to its immediate subdirectories so the
        // phone shows individual projects, not just the parent folder.
        var projects: [String] = []
        let fm = FileManager.default
        for root in roots {
            if let children = try? fm.contentsOfDirectory(atPath: root) {
                for child in children.sorted() where !child.hasPrefix(".") {
                    let full = (root as NSString).appendingPathComponent(child)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                        projects.append(full)
                    }
                }
            }
        }
        guard !projects.isEmpty else { return }
        print("[Quip] Broadcasting \(projects.count) project directories to phone")
        webSocketServer.broadcast(ProjectDirectoriesMessage(directories: projects))
    }

    @MainActor
    private func handleIncomingMessage(_ data: Data) {
        guard let type = MessageCoder.messageType(from: data) else {
            print("[Quip] handleIncomingMessage: unparseable message, size=\(data.count)")
            return
        }

        switch type {
        case "select_window":
            if let msg = MessageCoder.decode(SelectWindowMessage.self, from: data) {
                clientSelectedWindowId = msg.windowId
                windowManager.focusWindow(msg.windowId)
            }

        case "send_text":
            if let msg = MessageCoder.decode(SendTextMessage.self, from: data) {
                AuditLogger.log(messageType: "send_text", clientIdentifier: "ws-client", textContent: msg.text)
                if let window = windowManager.windows.first(where: { $0.id == msg.windowId }) {
                    if msg.pressReturn { thinkingWindows.insert(msg.windowId) }
                    let termApp = terminalAppForWindow(window)
                    windowManager.focusWindow(msg.windowId)
                    let name = window.name
                    let wn = window.windowNumber
                    // When iTerm2 session-write can target the session by UUID,
                    // the AX raise doesn't need to finish before AppleScript fires
                    // — `write text` bypasses focus. `focusDelay` returns 0 in
                    // that case. Otherwise we fall back to the old 80ms delay
                    // that the System Events/front-window path needs.
                    let delay = KeystrokeInjector.focusDelay(
                        path: .sendText, terminalApp: termApp,
                        iterm2SessionId: window.iterm2SessionId
                    )
                    let inject = {
                        self.keystrokeInjector.sendText(msg.text, to: msg.windowId, pressReturn: msg.pressReturn, terminalApp: termApp, windowName: name, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId)
                    }
                    if delay == 0 {
                        inject()
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { inject() }
                    }
                } else {
                    let known = windowManager.windows.map { $0.id }
                    print("[Quip] send_text DROPPED: unknown windowId=\(msg.windowId). Known windows: \(known)")
                    webSocketServer.broadcast(ErrorMessage(reason: "Window no longer exists"))
                }
            }
        case "quick_action":
            if let msg = MessageCoder.decode(QuickActionMessage.self, from: data) {
                AuditLogger.log(messageType: "quick_action", clientIdentifier: "ws-client", textContent: msg.action)
                print("[Quip] quick_action: action=\(msg.action) windowId=\(msg.windowId)")
                thinkingWindows.insert(msg.windowId)
                if let window = windowManager.windows.first(where: { $0.id == msg.windowId }) {
                    handleQuickAction(msg.action, for: window)
                } else {
                    let known = windowManager.windows.map { $0.id }
                    print("[Quip] quick_action DROPPED: unknown windowId=\(msg.windowId). Known windows: \(known)")
                    webSocketServer.broadcast(ErrorMessage(reason: "Window no longer exists"))
                }
            }
        case "stt_started":
            if let msg = MessageCoder.decode(STTStateMessage.self, from: data) {
                clientSelectedWindowId = msg.windowId
                pendingInputForWindow.insert(msg.windowId)
                thinkingWindows.insert(msg.windowId)
                // New user input → next response is a new turn, so rotate the
                // TTS session id. That interrupts any lingering audio from the
                // prior answer on the phone.
                ttsSessionIds.removeValue(forKey: msg.windowId)
                lastSpokenMarker.removeValue(forKey: msg.windowId)

                let wid = msg.windowId
                terminalStateDetector.setSTTActive(for: wid)
                if let window = windowManager.windows.first(where: { $0.id == wid }) {
                    terminalColorManager.updateColor(for: wid, state: .sttActive, terminalApp: terminalAppForWindow(window))
                }
                webSocketServer.broadcast(StateChangeMessage(windowId: wid, state: "stt_active"))

                // Snapshot terminal content on a background thread so main stays responsive.
                // Also update the high water mark so the next TTS delta only includes
                // content written AFTER the STT was sent — prevents replaying old responses.
                if let window = windowManager.windows.first(where: { $0.id == wid }) {
                    let termApp = terminalAppForWindow(window)
                    let wn = window.windowNumber
                    DispatchQueue.global(qos: .userInitiated).async { [keystrokeInjector] in
                        let content = keystrokeInjector.readContent(terminalApp: termApp, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId) ?? ""
                        DispatchQueue.main.async { [self] in
                            sttBaselineContent[wid] = content
                            outputHighWaterMarks[wid] = content
                            schedulePendingInputResponseCheck(windowId: wid, attempt: 0)
                        }
                    }
                } else {
                    schedulePendingInputResponseCheck(windowId: wid, attempt: 0)
                }
            }
        case "stt_ended":
            if let msg = MessageCoder.decode(STTStateMessage.self, from: data) {
                terminalStateDetector.clearSTTState(for: msg.windowId)
                if let window = windowManager.windows.first(where: { $0.id == msg.windowId }) {
                    terminalColorManager.updateColor(for: msg.windowId, state: .neutral, terminalApp: terminalAppForWindow(window))
                }
            }
        case "request_content":
            if let msg = MessageCoder.decode(RequestContentMessage.self, from: data) {
                // Throttle: at most once per 0.5s per window. Was 10s, which
                // meant 4-out-of-5 polls got dropped and button taps sat on
                // stale content for up to 10s. 500ms still protects the
                // AppleScript read from getting hammered but feels instant.
                let now = Date()
                if let last = lastContentRequestTime[msg.windowId],
                   now.timeIntervalSince(last) < 0.5 {
                    break
                }
                lastContentRequestTime[msg.windowId] = now

                if let window = windowManager.windows.first(where: { $0.id == msg.windowId }) {
                    let termApp = terminalAppForWindow(window)
                    let wn = window.windowNumber
                    let wid = msg.windowId
                    // Do the heavy AppleScript read + screenshot off main so it
                    // can't block send_text, auth, or other time-sensitive messages.
                    DispatchQueue.global(qos: .userInitiated).async { [keystrokeInjector, webSocketServer] in
                        let content = keystrokeInjector.readContent(terminalApp: termApp, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId) ?? ""
                        var lines = content.components(separatedBy: "\n")
                        // iTerm's buffer includes the whitespace cells Claude Code
                        // pads below its prompt box to wipe stale text. Shipped
                        // raw those blank rows land at the bottom of the phone's
                        // scroll view and shove the prompt out of sight.
                        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                            lines.removeLast()
                        }
                        let trimmed = lines.suffix(200).joined(separator: "\n")
                        let redacted = SecretRedactor.redact(trimmed)
                        let screenshot = keystrokeInjector.captureWindowScreenshot(cgWindowNumber: wn)
                        DispatchQueue.main.async {
                            webSocketServer.broadcast(TerminalContentMessage(windowId: wid, content: redacted, screenshot: screenshot))
                        }
                    }
                }
            }

        case "duplicate_window":
            if let msg = MessageCoder.decode(DuplicateWindowMessage.self, from: data) {
                print("[Quip] duplicate_window: sourceWindowId=\(msg.sourceWindowId)")
                if let source = windowManager.windows.first(where: { $0.id == msg.sourceWindowId }) {
                    // subtitle is documented as "Directory path or secondary info" in
                    // WindowManager.swift — so it might be empty, or it might be
                    // non-path text like "idle". Only treat it as a directory if it
                    // looks like one. Fall back to $HOME otherwise.
                    let rawSubtitle = source.subtitle
                    let looksLikePath = rawSubtitle.hasPrefix("/") || rawSubtitle.hasPrefix("~")
                    let dir: String
                    if looksLikePath {
                        dir = rawSubtitle
                    } else {
                        dir = NSHomeDirectory()
                        if !rawSubtitle.isEmpty {
                            print("[Quip] duplicate_window: subtitle \"\(rawSubtitle)\" is not a path, falling back to $HOME")
                        }
                    }
                    let termApp = terminalAppForWindow(source)
                    let cmd = UserDefaults.standard.string(forKey: "spawnCommand") ?? "claude"
                    let knownIds = Set(windowManager.windows.map(\.id))
                    keystrokeInjector.spawnWindow(in: dir, command: cmd, terminalApp: termApp)
                    // WindowManager's auto-refresh (~1 second) picks up the new window.
                    // When it does, switch the phone's selection to the new window so
                    // the user sees what they just spawned instead of the old card.
                    selectNewWindowAfterSpawn(knownIds: knownIds, attempt: 0)
                } else {
                    let known = windowManager.windows.map { $0.id }
                    print("[Quip] duplicate_window DROPPED: unknown source windowId=\(msg.sourceWindowId). Known: \(known)")
                    webSocketServer.broadcast(ErrorMessage(reason: "Source window no longer exists"))
                }
            }

        case "close_window":
            if let msg = MessageCoder.decode(CloseWindowMessage.self, from: data) {
                print("[Quip] close_window: windowId=\(msg.windowId)")
                if let window = windowManager.windows.first(where: { $0.id == msg.windowId }) {
                    let termApp = terminalAppForWindow(window)
                    keystrokeInjector.closeWindow(windowName: window.name, terminalApp: termApp)
                    // WindowManager's auto-refresh removes the closed window from the list.
                } else {
                    let known = windowManager.windows.map { $0.id }
                    print("[Quip] close_window DROPPED: unknown windowId=\(msg.windowId). Known: \(known)")
                    webSocketServer.broadcast(ErrorMessage(reason: "Window no longer exists"))
                }
            }

        case "spawn_window":
            if let msg = MessageCoder.decode(SpawnWindowMessage.self, from: data) {
                print("[Quip] spawn_window: directory=\(msg.directory)")
                let cmd = UserDefaults.standard.string(forKey: "spawnCommand") ?? "claude"
                let knownIds = Set(windowManager.windows.map(\.id))
                keystrokeInjector.spawnWindow(in: msg.directory, command: cmd, terminalApp: .iterm2)
                selectNewWindowAfterSpawn(knownIds: knownIds, attempt: 0)
            }

        case "arrange_windows":
            if let msg = MessageCoder.decode(ArrangeWindowsMessage.self, from: data) {
                print("[Quip] arrange_windows: layout=\(msg.layout)")
                handleArrangeWindows(layout: msg.layout)
            }

        default:
            break
        }
    }

    /// Drives the "arrange horizontally/vertically" command coming from the
    /// phone. Mirrors MenuBarView's local "Arrange Windows" path: filter to
    /// enabled windows, pick the main display, hand over to LayoutCalculator
    /// + WindowManager.arrangeWindows. Invalid layout strings are rejected
    /// with an error toast the phone can show.
    @MainActor
    private func handleArrangeWindows(layout: String) {
        guard let mode = LayoutMode.fromArrangeLayout(layout) else {
            webSocketServer.broadcast(ErrorMessage(reason: "Unknown arrangement: \(layout)"))
            return
        }
        let enabled = windowManager.windows.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            webSocketServer.broadcast(ErrorMessage(reason: "No enabled windows to arrange"))
            return
        }
        guard let display = windowManager.displays.first(where: { $0.isMain })
                ?? windowManager.displays.first else {
            webSocketServer.broadcast(ErrorMessage(reason: "No display available"))
            return
        }
        let frames = LayoutCalculator.calculate(mode: mode, windowCount: enabled.count)
        var targetFrames: [String: CGRect] = [:]
        for (index, window) in enabled.enumerated() where index < frames.count {
            targetFrames[window.id] = frames[index].toCGRect(in: display.frame)
        }
        if !windowManager.arrangeWindows(frames: targetFrames) {
            webSocketServer.broadcast(ErrorMessage(reason: "Grant Accessibility access to Quip in System Settings"))
            // Pop the Settings pane directly to the Accessibility list so the
            // user can grant in one click instead of hunting for it. Without
            // this, the error toast shows up every time they tap arrange with
            // no obvious way to fix it.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// After spawning a window via duplicate_window, poll WindowManager for the
    /// newly-detected window id and tell the phone to switch its selection to
    /// it. Polls every 250ms for up to 3 seconds. WindowManager's own scan runs
    /// roughly every second, so the new window typically shows up within 1-2
    /// polls. Gives up silently if nothing new appears in the time budget.
    @MainActor
    private func selectNewWindowAfterSpawn(knownIds: Set<String>, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            // Force a window list refresh so we don't wait for the 2-second timer
            windowManager.refreshWindowList()
            let currentIds = Set(windowManager.windows.map(\.id))
            let newIds = currentIds.subtracting(knownIds)
            // Prefer a terminal window (the one we just spawned) over any random
            // app window that happened to appear in the same refresh cycle.
            let newTerminalId = newIds.first(where: { id in
                windowManager.windows.first(where: { $0.id == id })?.isTerminal == true
            })
            if let newId = newTerminalId ?? newIds.first {
                print("[Quip] spawn: new window detected \(newId), enabling + switching selection")
                windowManager.toggleWindow(newId, enabled: true)
                clientSelectedWindowId = newId
                windowManager.focusWindow(newId)
                broadcastLayout()
                webSocketServer.broadcast(SelectWindowMessage(windowId: newId))
            } else if attempt < 12 {
                selectNewWindowAfterSpawn(knownIds: knownIds, attempt: attempt + 1)
            } else {
                print("[Quip] duplicate_window: no new window detected after 3s, skipping auto-select")
            }
        }
    }

    @MainActor
    private func handleQuickAction(_ action: String, for window: ManagedWindow) {
        let termApp = terminalAppForWindow(window)
        let wid = window.id
        let wn = window.windowNumber
        let wname = window.name
        // Focus the target window first so keystrokes land in the right place
        if action != "toggle_enabled" {
            windowManager.focusWindow(wid)
        }
        // 200ms lets windowManager.focusWindow's AX raise propagate before the
        // keystroke AppleScript fires — but only when we're falling back to
        // the front-window/System-Events path. When iTerm2 session-write has
        // a real session UUID, the keystroke targets the session directly and
        // can fire immediately. Skipping the 200ms there is the single biggest
        // button-latency win.
        let injectionDelay = KeystrokeInjector.focusDelay(
            path: .quickAction, terminalApp: termApp,
            iterm2SessionId: window.iterm2SessionId
        )
        let runAfterDelay: (@escaping () -> Void) -> Void = { work in
            if injectionDelay == 0 { work() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + injectionDelay) { work() } }
        }
        switch action {
        case "press_return":
            // Use sendText's direct iTerm2/Terminal AppleScript path (empty text
            // + newline) rather than System Events keystroke. Volume-PTT uses the
            // same path reliably; the System Events path races the AX raise and
            // drops Return on iTerm2 when multiple windows are open.
            runAfterDelay {
                keystrokeInjector.sendText("", to: wid, pressReturn: true, terminalApp: termApp, windowName: wname, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId)
            }
        case "press_ctrl_c":
            runAfterDelay {
                keystrokeInjector.sendKeystroke("ctrl+c", to: wid, terminalApp: termApp, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId)
            }
        case "press_ctrl_d":
            runAfterDelay {
                keystrokeInjector.sendKeystroke("ctrl+d", to: wid, terminalApp: termApp, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId)
            }
        case "press_escape":
            runAfterDelay {
                keystrokeInjector.sendKeystroke("escape", to: wid, terminalApp: termApp, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId)
            }
        case "press_tab":
            runAfterDelay {
                keystrokeInjector.sendKeystroke("tab", to: wid, terminalApp: termApp, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId)
            }
        case "press_backspace":
            runAfterDelay {
                keystrokeInjector.sendKeystroke("backspace", to: wid, terminalApp: termApp, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId)
            }
        case "press_y":
            runAfterDelay {
                keystrokeInjector.sendText("y", to: wid, pressReturn: true, terminalApp: termApp, windowName: wname, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId)
            }
        case "press_n":
            runAfterDelay {
                keystrokeInjector.sendText("n", to: wid, pressReturn: true, terminalApp: termApp, windowName: wname, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId)
            }
        case "clear_terminal":
            runAfterDelay {
                keystrokeInjector.sendText("/clear", to: wid, pressReturn: true, terminalApp: termApp, windowName: wname, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId)
            }
        case "restart_claude":
            runAfterDelay {
                keystrokeInjector.sendKeystroke("ctrl+c", to: wid, terminalApp: termApp, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    keystrokeInjector.sendText("claude", to: wid, pressReturn: true, terminalApp: termApp, windowName: wname, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId)
                }
            }
        case "toggle_enabled": windowManager.toggleWindow(window.id, enabled: !window.isEnabled)
        default: break
        }
    }

    /// Auto-track enabled terminal windows with the state detector
    /// Poll the terminal until its content is unchanged across two reads, indicating
    /// Claude has finished streaming tokens. Waits up to `maxWaitSeconds` total.
    /// Completion fires on main with the stable content, or nil if timeout.
    @MainActor
    private func waitForStableContent(termApp: TerminalApp, windowNumber: CGWindowID,
                                      iterm2SessionId: String? = nil,
                                      pollInterval: TimeInterval = 0.2,
                                      maxWaitSeconds: TimeInterval = 2.5,
                                      completion: @Sendable @escaping (String?) -> Void) {
        // Run the heavy AppleScript reads on a background thread so they
        // don't block main and starve tunnel message delivery.
        DispatchQueue.global(qos: .userInitiated).async { [keystrokeInjector] in
            let deadline = Date().addingTimeInterval(maxWaitSeconds)
            var previous = keystrokeInjector.readContent(terminalApp: termApp, cgWindowNumber: windowNumber, iterm2SessionId: iterm2SessionId) ?? ""

            while true {
                Thread.sleep(forTimeInterval: pollInterval)
                let current = keystrokeInjector.readContent(terminalApp: termApp, cgWindowNumber: windowNumber, iterm2SessionId: iterm2SessionId) ?? ""
                if current == previous && !current.isEmpty {
                    DispatchQueue.main.async { completion(current) }
                    return
                }
                if Date() >= deadline {
                    DispatchQueue.main.async { completion(current.isEmpty ? nil : current) }
                    return
                }
                previous = current
            }
        }
    }

    /// Compute what's new since last TTS. Returns empty if nothing changed.
    /// On first call for a window (no high-water mark), seeds the mark and returns empty
    /// so we don't read back old content from before the app started.
    @MainActor
    private func computeDelta(windowId: String, newContent: String) -> String {
        guard let previous = outputHighWaterMarks[windowId] else {
            // First time seeing this window — seed the mark, don't TTS old content
            return ""
        }
        // If content hasn't changed, nothing to speak
        if newContent == previous { return "" }
        // Take the last 25 lines — the Python filter handles stripping UI chrome
        let newLines = newContent.components(separatedBy: "\n")
        return Array(newLines.suffix(25)).joined(separator: "\n")
    }

    @MainActor
    private func syncTrackedWindows() {
        let terminalBundleIds: Set<String> = [
            TerminalApp.terminal.bundleIdentifier,
            TerminalApp.iterm2.bundleIdentifier
        ]
        let enabledTerminals = windowManager.windows.filter {
            $0.isEnabled && terminalBundleIds.contains($0.bundleId)
        }
        // Track new windows
        for window in enabledTerminals {
            if terminalStateDetector.trackedWindows[window.id] == nil {
                terminalStateDetector.trackWindow(window.id, shellPid: window.pid)
            }
        }
        // Untrack removed/disabled windows
        let enabledIds = Set(enabledTerminals.map(\.id))
        for windowId in terminalStateDetector.trackedWindows.keys {
            if !enabledIds.contains(windowId) {
                terminalStateDetector.untrackWindow(windowId)
            }
        }

        // Prune per-window state for windows that no longer exist at all.
        // Without this, dicts like outputHighWaterMarks and sttBaselineContent
        // (each value holds tens of KB of terminal content) accumulate entries
        // for long-dead windows over the app's lifetime.
        let allCurrentIds = Set(windowManager.windows.map(\.id))
        outputHighWaterMarks = outputHighWaterMarks.filter { allCurrentIds.contains($0.key) }
        lastSpokenMarker = lastSpokenMarker.filter { allCurrentIds.contains($0.key) }
        sttBaselineContent = sttBaselineContent.filter { allCurrentIds.contains($0.key) }
        lastContentRequestTime = lastContentRequestTime.filter { allCurrentIds.contains($0.key) }
        ttsGeneration = ttsGeneration.filter { allCurrentIds.contains($0.key) }
        ttsSessionIds = ttsSessionIds.filter { allCurrentIds.contains($0.key) }
        pendingInputForWindow = pendingInputForWindow.intersection(allCurrentIds)
        thinkingWindows = thinkingWindows.intersection(allCurrentIds)
        if let selected = clientSelectedWindowId, !allCurrentIds.contains(selected) {
            clientSelectedWindowId = nil
        }
    }

    private func terminalAppForWindow(_ window: ManagedWindow) -> TerminalApp {
        window.bundleId == TerminalApp.iterm2.bundleIdentifier ? .iterm2 : .terminal
    }

    /// Find the 1-based window index in the terminal app by matching
    /// the managed window's position against AX window positions.
    /// Terminal apps order their windows differently than CG, so we
    /// enumerate AX windows for the same PID and find which index matches.
    private func windowIndexForWindow(_ window: ManagedWindow, terminalApp: TerminalApp) -> Int {
        let appElement = AXUIElementCreateApplication(window.pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            return 1
        }

        // Match by title first (most reliable for multiple windows of same app)
        for (index, axWindow) in axWindows.enumerated() {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
               let axTitle = titleRef as? String {
                if axTitle == window.name {
                    print("[Quip] Title match '\(axTitle)' -> window \(index + 1)")
                    return index + 1
                }
            }
        }

        // Fallback: match by CG window number via position
        // Refresh bounds from CG first for accuracy
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        if let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            for info in infoList {
                guard let wn = info[kCGWindowNumber as String] as? CGWindowID,
                      wn == window.windowNumber,
                      let boundsDict = info[kCGWindowBounds as String] as? [String: Any] else { continue }
                let freshX = boundsDict["X"] as? CGFloat ?? window.bounds.origin.x
                let freshY = boundsDict["Y"] as? CGFloat ?? window.bounds.origin.y

                for (index, axWindow) in axWindows.enumerated() {
                    var posRef: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success else { continue }
                    var axPos = CGPoint.zero
                    AXValueGetValue(posRef as! AXValue, .cgPoint, &axPos)

                    if abs(axPos.x - freshX) < 10 && abs(axPos.y - freshY) < 10 {
                        print("[Quip] Position match -> window \(index + 1)")
                        return index + 1
                    }
                }
            }
        }

        return 1
    }
}
