import SwiftUI

@main
struct VoiceCodeMacApp: App {
    @State private var windowManager = WindowManager()
    @State private var webSocketServer = WebSocketServer()
    @State private var bonjourAdvertiser = BonjourAdvertiser()
    @State private var terminalStateDetector = TerminalStateDetector()
    @State private var terminalColorManager = TerminalColorManager()
    @State private var keystrokeInjector = KeystrokeInjector()
    @State private var tunnel = CloudflareTunnel()

    init() {
        // Start services immediately — .onAppear may not fire reliably
        DispatchQueue.main.async {
            try? "init called".write(toFile: "/tmp/vc_debug.txt", atomically: true, encoding: .utf8)
        }
    }

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
                .onAppear { startServices() }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 960, height: 640)

        MenuBarExtra("VoiceCode", systemImage: "waveform.circle.fill") {
            MenuBarView()
                .environment(windowManager)
                .environment(webSocketServer)
                .environment(bonjourAdvertiser)
                .environment(tunnel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(windowManager)
                .environment(webSocketServer)
                .environment(bonjourAdvertiser)
        }
    }

    private func startServices() {
        try? "startServices called".write(toFile: "/tmp/vc_debug.txt", atomically: true, encoding: .utf8)
        webSocketServer.start()
        tunnel.start()

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
                    keystrokeInjector.sendText(msg.text, to: msg.windowId, pressReturn: msg.pressReturn, terminalApp: terminalAppForWindow(window))
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
        case "clear_terminal": keystrokeInjector.sendText("clear", to: window.id, pressReturn: true, terminalApp: termApp)
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
}
