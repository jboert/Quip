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
                .onAppear { startServicesOnce() }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 960, height: 640)

        MenuBarExtra("Quip", systemImage: "waveform.circle.fill") {
            MenuBarView()
                .environment(windowManager)
                .environment(webSocketServer)
                .environment(bonjourAdvertiser)
                .environment(tunnel)
                .onAppear { startServicesOnce() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(windowManager)
                .environment(webSocketServer)
                .environment(bonjourAdvertiser)
        }
    }

    @State private var servicesStarted = false

    private func startServicesOnce() {
        guard !servicesStarted else { return }
        servicesStarted = true
        webSocketServer.start()
        tunnel.start()
        bonjourAdvertiser.startAdvertising()

        webSocketServer.onMessageReceived = { [self] data in
            DispatchQueue.main.async {
                self.handleIncomingMessage(data)
            }
        }

        terminalStateDetector.startMonitoring()
        windowManager.refreshDisplays()
        windowManager.refreshWindowList()

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            DispatchQueue.main.async {
                windowManager.refreshWindowList()
                windowManager.refreshSubtitles()
                broadcastLayout()
            }
        }
    }

    @MainActor
    private func broadcastLayout() {
        guard webSocketServer.connectedClientCount > 0 else { return }
        let display = windowManager.displays.first(where: { $0.isMain }) ?? windowManager.displays.first
        let screenBounds = display?.frame ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let states = windowManager.windows.filter(\.isEnabled).map { window in
            window.toWindowState(
                state: terminalStateDetector.windowStates[window.id]?.rawValue ?? "neutral",
                screenBounds: screenBounds
            )
        }
        let update = LayoutUpdate(monitor: display?.name ?? "Display 1", windows: states)
        webSocketServer.broadcast(update)
    }

    @MainActor
    private func handleIncomingMessage(_ data: Data) {
        guard let type = MessageCoder.messageType(from: data) else { return }

        switch type {
        case "select_window":
            if let msg = MessageCoder.decode(SelectWindowMessage.self, from: data) {
                windowManager.focusWindow(msg.windowId)
            }

        case "send_text":
            if let msg = MessageCoder.decode(SendTextMessage.self, from: data) {
                if let window = windowManager.windows.first(where: { $0.id == msg.windowId }) {
                    let termApp = terminalAppForWindow(window)
                    // Focus the window via AX first, then target by name in AppleScript
                    windowManager.focusWindow(msg.windowId)
                    let name = window.name
                    let wn = window.windowNumber
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.keystrokeInjector.sendText(msg.text, to: msg.windowId, pressReturn: msg.pressReturn, terminalApp: termApp, windowName: name, cgWindowNumber: wn)
                    }
                }
            }
        case "quick_action":
            if let msg = MessageCoder.decode(QuickActionMessage.self, from: data) {
                if let window = windowManager.windows.first(where: { $0.id == msg.windowId }) {
                    handleQuickAction(msg.action, for: window)
                }
            }
        case "stt_started":
            if let msg = MessageCoder.decode(STTStateMessage.self, from: data) {
                terminalStateDetector.setSTTActive(for: msg.windowId)
                if let window = windowManager.windows.first(where: { $0.id == msg.windowId }) {
                    terminalColorManager.updateColor(for: msg.windowId, state: .sttActive, terminalApp: terminalAppForWindow(window))
                }
                webSocketServer.broadcast(StateChangeMessage(windowId: msg.windowId, state: "stt_active"))
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
                if let window = windowManager.windows.first(where: { $0.id == msg.windowId }) {
                    let termApp = terminalAppForWindow(window)
                    let wn = window.windowNumber
                    let content = keystrokeInjector.readContent(terminalApp: termApp, cgWindowNumber: wn) ?? ""
                    // Send only last ~200 lines to keep payload reasonable
                    let lines = content.components(separatedBy: "\n")
                    let trimmed = lines.suffix(200).joined(separator: "\n")
                    let screenshot = keystrokeInjector.captureWindowScreenshot(cgWindowNumber: wn)
                    webSocketServer.broadcast(TerminalContentMessage(windowId: msg.windowId, content: trimmed, screenshot: screenshot))
                }
            }
        default:
            break
        }
    }

    @MainActor
    private func handleQuickAction(_ action: String, for window: ManagedWindow) {
        let termApp = terminalAppForWindow(window)
        switch action {
        case "press_return": keystrokeInjector.sendKeystroke("return", to: window.id, terminalApp: termApp)
        case "press_ctrl_c": keystrokeInjector.sendKeystroke("ctrl+c", to: window.id, terminalApp: termApp)
        case "press_ctrl_d": keystrokeInjector.sendKeystroke("ctrl+d", to: window.id, terminalApp: termApp)
        case "press_escape": keystrokeInjector.sendKeystroke("escape", to: window.id, terminalApp: termApp)
        case "press_tab": keystrokeInjector.sendKeystroke("tab", to: window.id, terminalApp: termApp)
        case "press_y":
            windowManager.focusWindow(window.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.keystrokeInjector.sendText("y", to: window.id, pressReturn: true, terminalApp: termApp)
            }
        case "press_n":
            windowManager.focusWindow(window.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.keystrokeInjector.sendText("n", to: window.id, pressReturn: true, terminalApp: termApp)
            }
        case "clear_terminal": keystrokeInjector.sendText("/clear", to: window.id, pressReturn: true, terminalApp: termApp)
        case "restart_claude":
            keystrokeInjector.sendKeystroke("ctrl+c", to: window.id, terminalApp: termApp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                keystrokeInjector.sendText("claude", to: window.id, pressReturn: true, terminalApp: termApp)
            }
        case "toggle_enabled": windowManager.toggleWindow(window.id, enabled: !window.isEnabled)
        default: break
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
