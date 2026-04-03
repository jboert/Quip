import SwiftUI
import AVFoundation

// Controls orientation lock — portrait when disconnected, landscape when connected
class AppOrientationDelegate: NSObject, UIApplicationDelegate {
    static var allowLandscape = false

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.allowLandscape ? .landscape : .portrait
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
    @State private var isRecording = false
    @State private var terminalContentText: String?
    @State private var terminalContentScreenshot: String?
    @State private var terminalContentWindowId: String?

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
                monitorName: monitorName,
                onStartRecording: { startRecording() },
                onStopRecording: { stopRecording() },
                onRequestContent: { windowId in
                    client.send(RequestContentMessage(windowId: windowId))
                }
            )
            .onAppear {
                setup()
                bonjourBrowser.startBrowsing()
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
                volumeHandler.startMonitoring(windowCount: update.windows.count)
                // Switch to landscape on first layout received
                if wasEmpty && !update.windows.isEmpty {
                    AppOrientationDelegate.allowLandscape = true
                    // Force rotation via UIDevice
                    UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
                    }
                    UIViewController.attemptRotationToDeviceOrientation()
                }
            }
        }

        client.onStateChange = { windowId, newState in
            DispatchQueue.main.async {
                if let i = windows.firstIndex(where: { $0.id == windowId }) {
                    let w = windows[i]
                    windows[i] = WindowState(
                        id: w.id, name: w.name, app: w.app, enabled: w.enabled,
                        frame: w.frame, state: newState, color: w.color
                    )
                }
            }
        }

        volumeHandler.onSelectionChanged = { index in
            DispatchQueue.main.async {
                guard index >= 0, index < windows.count else { return }
                let newId = windows[index].id
                selectedWindowId = newId
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
        speech.startRecording()
        isRecording = true
        // Haptic: medium impact for recording start
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        client.send(STTStateMessage.started(windowId: windowId))
    }

    @MainActor
    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false // Set immediately to prevent re-entry from rapid presses
        // Haptic: double light tap for recording stop
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            generator.impactOccurred()
        }
        let windowId = selectedWindowId
        NSLog("[Quip] stopRecording called, windowId=%@", windowId ?? "nil")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            let text = speech.stopRecording()
            NSLog("[Quip] Transcribed: '%@' (length=%d)", text, text.count)
            if let windowId {
                client.send(STTStateMessage.ended(windowId: windowId))
                if !text.isEmpty {
                    NSLog("[Quip] Sending text to window %@", windowId)
                    client.send(SendTextMessage(windowId: windowId, text: text, pressReturn: true))
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
    @Binding var terminalContentWindowId: String?
    var monitorName: String
    var onStartRecording: () -> Void
    var onStopRecording: () -> Void
    var onRequestContent: (String) -> Void

    @AppStorage("lastURL") private var urlText: String = ""
    @AppStorage("recentConnectionsData") private var recentConnectionsData: Data = Data()
    @State private var showQRScanner = false
    @State private var recentConnections: [SavedConnection] = []
    @State private var editingConnection: SavedConnection?
    @State private var renameText: String = ""

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.09)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if !client.isConnected && !client.isConnecting {
                    connectBar
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                } else {
                    connectedBar
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                }

                windowLayout
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)

                bottomBar
                    .padding(.horizontal, 6)
            }
        }
        .overlay {
            if isRecording {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { onStopRecording() }

                VStack {
                    Spacer()
                    HStack {
                        Circle()
                            .fill(.red)
                            .frame(width: 10, height: 10)
                            .opacity(0.8)
                        Text("Recording — tap to stop")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.2))
                    .clipShape(Capsule())
                    .padding(.bottom, 20)
                }
                .allowsHitTesting(true)
                .onTapGesture { onStopRecording() }
            }
        }
        .overlay {
            if let content = terminalContentText {
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
                    }
                )
            }
        }
        .overlay { HiddenVolumeView().frame(width: 1, height: 1) }
        .preferredColorScheme(.dark)
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
        .sheet(isPresented: $showQRScanner) {
            QRScannerView { code in
                urlText = code
                showQRScanner = false
                doConnect()
            }
        }
    }

    // MARK: - Connect Bar (disconnected)

    private var connectBar: some View {
        VStack(spacing: 6) {
            // URL input row
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)

                TextField("wss://...", text: $urlText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onSubmit { doConnect() }

                Button { pasteFromClipboard() } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 36, height: 36)
                }

                Button { showQRScanner = true } label: {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 36, height: 36)
                }

                Button { doConnect() } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(urlText.isEmpty ? .white.opacity(0.2) : .blue)
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
                                    .foregroundStyle(.green.opacity(0.7))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.8))
                                    Text("\(host.host):\(host.port)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                                Spacer()
                                Text("Local")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.green.opacity(0.5))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.green.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.green.opacity(0.06))
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
                                            .foregroundStyle(.white.opacity(0.8))
                                            .lineLimit(1)
                                        Text(conn.url)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.3))
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.2))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(.white.opacity(0.06))
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
                .fill(client.isConnected ? Color.green : Color.yellow)
                .frame(width: 6, height: 6)
            Text(client.isConnected ? "Connected" : "Connecting\u{2026}")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            if let error = client.lastError {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.red.opacity(0.7))
            }
            if isRecording {
                Text("REC")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(red: 0.9, green: 0.65, blue: 0.15))
            }
            Spacer()
            Button {
                client.disconnect()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
            if let sel = windows.first(where: { $0.id == selectedWindowId }) {
                Circle().fill(Color(hex: sel.color)).frame(width: 5, height: 5)
                Text(" \(sel.name)")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
        }
    }

    // MARK: - Window Layout

    private var windowLayout: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.015))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.white.opacity(0.03), lineWidth: 0.5)
                    )

                if windows.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "macwindow.on.rectangle")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(.white.opacity(0.1))
                        Text(client.isConnected ? "No windows" : "Enter tunnel URL")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.15))
                    }
                } else {
                    ForEach(windows) { window in
                        let rect = windowRect(frame: window.frame, in: geo.size, inset: 3)
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
        } else if urlText.contains(":") {
            urlStr = "ws://\(urlText)"
        } else {
            urlStr = "wss://\(urlText)"
        }
        if let url = URL(string: urlStr) {
            client.connect(to: url)
            addToRecents(urlStr)
        }
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

    private func addToRecents(_ url: String) {
        if let i = recentConnections.firstIndex(where: { $0.url == url }) {
            recentConnections[i].lastUsed = Date()
        } else {
            recentConnections.append(SavedConnection(url: url))
        }
        // Keep max 10
        let unpinned = recentConnections.filter { !$0.pinned }.sorted { $0.lastUsed > $1.lastUsed }
        if unpinned.count > 8 {
            let toRemove = Set(unpinned.dropFirst(8).map(\.id))
            recentConnections.removeAll { toRemove.contains($0.id) }
        }
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
        AppOrientationDelegate.allowLandscape = client.isConnected
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let mask: UIInterfaceOrientationMask = client.isConnected ? .landscape : .portrait
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        // Force UIKit to re-query supported orientations
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
        let str: String
        switch action {
        case .pressReturn: str = "press_return"
        case .cancel: str = "press_ctrl_c"
        case .clearTerminal: str = "clear_terminal"
        case .restartClaude: str = "restart_claude"
        case .toggleEnabled: str = "toggle_enabled"
        case .viewOutput: return // handled above
        }
        client.send(QuickActionMessage(windowId: windowId, action: str))
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
