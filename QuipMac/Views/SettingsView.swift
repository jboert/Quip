// SettingsView.swift
// QuipMac — macOS Settings window with tabbed configuration panels

import SwiftUI
import Darwin

struct SettingsView: View {
    @Environment(WindowManager.self) private var windowManager
    @Environment(WebSocketServer.self) private var webSocketServer
    @Environment(BonjourAdvertiser.self) private var bonjourAdvertiser
    @Environment(PINManager.self) private var pinManager

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            LayoutsTab()
                .tabItem {
                    Label("Layouts", systemImage: "rectangle.3.group")
                }

            DirectoriesTab()
                .tabItem {
                    Label("Directories", systemImage: "folder")
                }

            ConnectionTab()
                .tabItem {
                    Label("Connection", systemImage: "wifi")
                }

            SecurityTab()
                .tabItem {
                    Label("Security", systemImage: "lock.fill")
                }

            ColorsTab()
                .tabItem {
                    Label("Colors", systemImage: "paintpalette")
                }

            NotificationsTab()
                .tabItem {
                    Label("Notifications", systemImage: "bell.badge")
                }

            DiagnosticsTab()
                .tabItem {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
        }
        // Vertical resize is the common ask (long tabs like Connection
        // overflow). Width stays fixed at 520 so content doesn't get spread
        // out across a stretched gutter. `.top` alignment so extra vertical
        // space falls below content rather than centering it.
        .frame(minHeight: 460, idealHeight: 460, maxHeight: .infinity,
               alignment: .top)
        .frame(width: 520)
    }
}

// MARK: - Notifications Tab

/// Collects the APNs auth-key configuration (.p8 file, Key ID, Team ID,
/// Bundle ID) + a Test Push button. The .p8 goes into the Keychain via
/// APNsKeyStore; the three ID fields sit in UserDefaults. No pushes fire
/// from here — the only send is Test Push, which loops registered
/// devices and reports per-device success/failure inline.
private struct NotificationsTab: View {
    @Environment(PushNotificationService.self) private var pushService

    @AppStorage("apnsKeyId") private var keyId: String = ""
    @AppStorage("apnsTeamId") private var teamId: String = ""
    @AppStorage("apnsBundleId") private var bundleId: String = "com.quip.QuipiOS"

    @State private var hasKey: Bool = APNsKeyStore.hasKey
    @State private var importStatus: String?
    @State private var testStatus: [String] = []
    @State private var isSending: Bool = false

    var body: some View {
        Form {
            Section("APNs Auth Key") {
                HStack {
                    Text(hasKey ? "Key: stored in Keychain" : "Key: (not set)")
                        .foregroundStyle(hasKey ? .primary : .secondary)
                    Spacer()
                    Button(hasKey ? "Replace .p8…" : "Import .p8…") { importKey() }
                    if hasKey {
                        Button("Clear") { clearKey() }
                    }
                }
                if let importStatus {
                    Text(importStatus)
                        .font(.caption)
                        .foregroundStyle(importStatus.hasPrefix("Error") ? .red : .secondary)
                }
                TextField("Key ID", text: $keyId)
                TextField("Team ID", text: $teamId)
                TextField("Bundle ID", text: $bundleId)
            }

            Section("Registered Devices (\(pushService.devices.count))") {
                if pushService.devices.isEmpty {
                    Text("No iPhones have registered yet. Open Quip on the phone and connect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pushService.devices, id: \.token) { device in
                        HStack {
                            Text(device.token.prefix(12) + "…")
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Text(device.environment)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Button {
                        Task { await sendTestPush() }
                    } label: {
                        Label("Send Test Push", systemImage: "paperplane")
                    }
                    .disabled(isSending || !hasKey || keyId.isEmpty || teamId.isEmpty || bundleId.isEmpty || pushService.devices.isEmpty)
                    if isSending { ProgressView().scaleEffect(0.7) }
                }
                ForEach(testStatus, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(line.hasPrefix("✓") ? Color.secondary : Color.red)
                }
            }
        }
        .padding()
    }

    private func importKey() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Import"
        panel.message = "Select your APNs .p8 auth key"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                if APNsKeyStore.set(data) {
                    hasKey = true
                    importStatus = "Imported \(url.lastPathComponent)"
                    // New key → cached APNsClient's parsed private key
                    // is stale. Drop it so the next send re-reads.
                    pushService.invalidateClient()
                } else {
                    importStatus = "Error: could not save to Keychain"
                }
            } catch {
                importStatus = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func clearKey() {
        if APNsKeyStore.clear() {
            hasKey = false
            importStatus = "Key cleared"
        }
    }

    private func sendTestPush() async {
        testStatus = []
        isSending = true
        defer { isSending = false }

        let hostName = Host.current().localizedName ?? "Mac"
        let payload: [String: Any] = [
            "aps": [
                "alert": ["title": "Quip", "body": "Test push from \(hostName)"],
                "sound": "default"
            ],
            "quip_event": "test_push"
        ]
        let devicesSnapshot = pushService.devices
        let client: APNsClient
        do {
            client = try pushService.cachedClient(keyId: keyId, teamId: teamId, bundleId: bundleId)
        } catch {
            testStatus.append("Error creating client: \(error)")
            return
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            testStatus.append("Error: could not encode payload")
            return
        }
        for device in devicesSnapshot {
            do {
                try await client.send(payloadData: body, toDevice: device)
                testStatus.append("✓ \(device.token.prefix(8))… sent")
            } catch APNsError.unregistered {
                testStatus.append("⚠ \(device.token.prefix(8))… dropped (unregistered)")
                pushService.removeDevice(token: device.token)
            } catch {
                testStatus.append("✗ \(device.token.prefix(8))… \(error)")
            }
        }
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @Environment(WhisperStatusStore.self) private var whisperStatus
    @AppStorage("defaultTerminalApp") private var defaultTerminalApp: String = TerminalApp.iterm2.rawValue
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @AppStorage("showInDock") private var showInDock = true
    @AppStorage("mirrorDesktop") private var mirrorDesktop = false

    /// Re-probe TCC perms every 3s while this tab is visible so the row
    /// status flips green within seconds of the user granting in System
    /// Settings — without forcing the user to bounce back into Quip to
    /// see it. TimelineView is the cheapest reactive timer in SwiftUI.
    private let permissionProbe = PermissionProbeService()

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build)) — built \(buildTimestamp)"
    }

    /// Mtime of the compiled binary. Bumps every rebuild without needing
    /// a project-level version bump — useful for "did my reinstall land".
    private var buildTimestamp: String {
        guard let path = Bundle.main.executablePath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return "?" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version") {
                    Text(versionString)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Section("Permissions") {
                TimelineView(.periodic(from: .now, by: 3.0)) { _ in
                    let perms = permissionProbe.probe()
                    macPermRow(name: "Accessibility", granted: perms.accessibility, pane: .accessibility)
                    macPermRow(name: "Automation (iTerm)", granted: perms.appleEvents, pane: .automation)
                    macPermRow(name: "Screen Recording", granted: perms.screenRecording, pane: .screenRecording)
                }
            }

            Section("Terminal") {
                Picker("Default Terminal App", selection: $defaultTerminalApp) {
                    ForEach(TerminalApp.allCases) { app in
                        Text(app.rawValue).tag(app.rawValue)
                    }
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle("Show in menu bar", isOn: $showInMenuBar)
                Toggle("Show in Dock", isOn: $showInDock)
            }

            Section("Phone Display") {
                Toggle("Mirror desktop terminals", isOn: $mirrorDesktop)
                Text("When on, every visible Terminal.app and iTerm2 window shows up on the phone — tap a dimmed one to start driving it. When off, only windows you've explicitly enabled are visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Window Refresh") {
                Text("Windows are automatically refreshed when the app activates and when displays change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dictation Recognizer") {
                whisperStatusRow()
                Text("Phone auto-selects Mac Whisper when the model is ready, otherwise falls back to on-device SFSpeech.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func whisperStatusRow() -> some View {
        // Mirror the macPermRow look: status glyph + label + tail detail. No
        // action buttons — retrying model load is a relaunch-level concern,
        // wiring a manual retry is follow-up work.
        let state = whisperStatus.state
        HStack(spacing: 8) {
            Image(systemName: whisperIcon(for: state))
                .foregroundStyle(whisperColor(for: state))
            Text("Mac Whisper")
            Spacer()
            Text(whisperDetail(for: state))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func whisperIcon(for state: WhisperState) -> String {
        switch state {
        case .ready:            return "checkmark.circle.fill"
        case .preparing:        return "hourglass"
        case .downloading:      return "arrow.down.circle"
        case .failed:           return "xmark.circle.fill"
        }
    }

    private func whisperColor(for state: WhisperState) -> Color {
        switch state {
        case .ready:            return .green
        case .preparing:        return .secondary
        case .downloading:      return .blue
        case .failed:           return .red
        }
    }

    private func whisperDetail(for state: WhisperState) -> String {
        switch state {
        case .ready:
            return "ready — phone will use remote path"
        case .preparing:
            return "loading model…"
        case .downloading(let progress):
            return "downloading \(Int(progress * 100))%"
        case .failed(let message):
            return message
        }
    }

    /// One TCC perm row. Granted = green check. Denied = red ✗ + a "Grant"
    /// button that drops the user straight into the matching System Settings
    /// pane via an x-apple.systempreferences URL — no nav required.
    @ViewBuilder
    private func macPermRow(name: String, granted: Bool, pane: MacSettingsPane) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.red)
            Text(name)
            Spacer()
            if !granted {
                Button("Grant") { openSettingsPane(pane) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func openSettingsPane(_ pane: MacSettingsPane) {
        let urlString: String
        switch pane {
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .automation:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Layouts Tab

private struct LayoutsTab: View {
    @AppStorage("savedPresets") private var savedPresetsData: Data = Data()
    @State private var presets: [SavedLayoutPreset] = []
    @State private var editingPreset: SavedLayoutPreset?

    var body: some View {
        VStack(spacing: 0) {
            if presets.isEmpty {
                ContentUnavailableView(
                    "No Saved Layouts",
                    systemImage: "rectangle.3.group",
                    description: Text("Arrange your windows and save the layout as a preset.")
                )
            } else {
                List {
                    ForEach(presets) { preset in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.body.weight(.medium))

                                HStack(spacing: 8) {
                                    Label(preset.mode.label, systemImage: preset.mode.icon)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Text(preset.createdAt, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            Spacer()

                            Button {
                                editingPreset = preset
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)

                            Button(role: .destructive) {
                                deletePreset(preset)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .onAppear { loadPresets() }
        .sheet(item: $editingPreset) { preset in
            RenamePresetSheet(preset: preset) { newName in
                renamePreset(preset, to: newName)
            }
        }
    }

    private func loadPresets() {
        if let decoded = try? JSONDecoder().decode([SavedLayoutPreset].self, from: savedPresetsData) {
            presets = decoded
        }
    }

    private func savePresets() {
        if let encoded = try? JSONEncoder().encode(presets) {
            savedPresetsData = encoded
        }
    }

    private func deletePreset(_ preset: SavedLayoutPreset) {
        presets.removeAll { $0.id == preset.id }
        savePresets()
    }

    private func renamePreset(_ preset: SavedLayoutPreset, to name: String) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index].name = name
            savePresets()
        }
    }
}

// MARK: - Rename Preset Sheet

private struct RenamePresetSheet: View {
    let preset: SavedLayoutPreset
    let onRename: (String) -> Void

    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(preset: SavedLayoutPreset, onRename: @escaping (String) -> Void) {
        self.preset = preset
        self.onRename = onRename
        self._name = State(initialValue: preset.name)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Layout")
                .font(.headline)

            TextField("Layout name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Rename") {
                    onRename(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}

// MARK: - Directories Tab

private struct DirectoriesTab: View {
    @AppStorage("projectDirectories") private var directoriesData: Data = Data()
    @State private var directories: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            if directories.isEmpty {
                ContentUnavailableView(
                    "No Project Directories",
                    systemImage: "folder.badge.plus",
                    description: Text("Add directories to quickly spawn new terminal sessions.")
                )
            } else {
                List {
                    ForEach(directories, id: \.self) { dir in
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.secondary)
                            Text(dir)
                                .font(.body)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Button(role: .destructive) {
                                directories.removeAll { $0 == dir }
                                saveDirectories()
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button {
                    addDirectory()
                } label: {
                    Label("Add Directory", systemImage: "plus")
                }
                .padding(8)
            }
        }
        .onAppear { loadDirectories() }
    }

    private func loadDirectories() {
        if let decoded = try? JSONDecoder().decode([String].self, from: directoriesData) {
            directories = decoded
        }
    }

    private func saveDirectories() {
        if let encoded = try? JSONEncoder().encode(directories) {
            directoriesData = encoded
        }
    }

    private func addDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project directory"

        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            if !directories.contains(path) {
                directories.append(path)
                saveDirectories()
            }
        }
    }
}

// MARK: - Connection Tab

private struct ConnectionTab: View {
    @Environment(WebSocketServer.self) private var webSocketServer
    @Environment(BonjourAdvertiser.self) private var bonjourAdvertiser
    @Environment(TailscaleService.self) private var tailscale
    @Environment(CloudflareTunnel.self) private var tunnel
    @Environment(ConnectionLog.self) private var connectionLog

    @AppStorage("wsPort") private var port: Int = 8765
    @AppStorage("bonjourServiceName") private var serviceName: String = "Quip"
    @AppStorage("networkMode") private var networkModeRaw: String = NetworkMode.cloudflareTunnel.rawValue
    @AppStorage("tailscaleHostnameOverride") private var tailscaleOverride: String = ""
    @AppStorage("requirePINForLocal") private var requirePINForLocal = false
    @AppStorage("spawnCommand") private var spawnCommand: String = "claude"

    private var networkMode: NetworkMode {
        NetworkMode(rawValue: networkModeRaw) ?? .cloudflareTunnel
    }

    private var modeCaption: String {
        switch networkMode {
        case .cloudflareTunnel:
            return "Cloudflare tunnel enables connections from anywhere. Local connections always require PIN when tunnel is active."
        case .tailscale:
            return "Both devices must be on your Tailscale network. The URL stays stable across restarts."
        case .localOnly:
            return "Clients must be on the same network. QR code shows local address."
        }
    }

    var body: some View {
        Form {
            Section("WebSocket Server") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(webSocketServer.isRunning ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(webSocketServer.isRunning ? "Running" : "Stopped")
                    }
                }

                LabeledContent("Connected Clients") {
                    Text("\(webSocketServer.connectedClientCount)")
                        .monospacedDigit()
                }

                TextField("Port", value: $port, format: .number)
                    .frame(width: 100)
            }

            Section("Bonjour Discovery") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(bonjourAdvertiser.isAdvertising ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(bonjourAdvertiser.isAdvertising ? "Advertising" : "Stopped")
                    }
                }

                TextField("Service Name", text: $serviceName)
            }

            Section("Network Mode") {
                Picker("Network Mode", selection: $networkModeRaw) {
                    ForEach(NetworkMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(modeCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if networkMode == .tailscale {
                    LabeledContent("Hostname") {
                        if tailscale.hostname.isEmpty {
                            Text("Not detected")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Text(tailscale.hostname)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }

                    Button {
                        tailscale.refresh()
                    } label: {
                        Label("Re-detect", systemImage: "arrow.clockwise")
                    }

                    TextField("Hostname override (optional)", text: $tailscaleOverride)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: tailscaleOverride) { _, _ in
                            tailscale.refresh()
                        }

                    if let err = tailscale.lastError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Toggle("Require PIN for local connections", isOn: $requirePINForLocal)
                    .onChange(of: requirePINForLocal) { _, newValue in
                        webSocketServer.requireAuth = newValue
                    }
            }

            Section("New Window Spawning") {
                TextField("Command to run on new window", text: $spawnCommand)
                    .textFieldStyle(.roundedBorder)
                Text("Runs after `cd <dir>` when the phone asks for a duplicate window. Leave empty for a bare shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics — Connection URLs") {
                // Show every URL the phone could reasonably try right now —
                // LAN, Tailscale, Cloudflare tunnel — each with a one-click
                // copy. Debugging "nothing's loading on the phone" used to
                // mean guessing which URL it had saved; now it's literally
                // "copy this into the app's URL field."
                urlRow(label: "LAN", url: Self.lanWSURL(port: port))
                if let tsURL = tailscaleWSURL {
                    urlRow(label: "Tailscale", url: tsURL)
                }
                if !tunnel.webSocketURL.isEmpty {
                    urlRow(label: "Cloudflare", url: tunnel.webSocketURL)
                }
            }

            Section("Diagnostics — Recent Connections") {
                if connectionLog.events.isEmpty {
                    Text("No connection attempts recorded yet.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(connectionLog.events) { event in
                                connectionLogRow(event)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)

                    Button {
                        connectionLog.clear()
                    } label: {
                        Label("Clear Log", systemImage: "trash")
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func urlRow(label: String, url: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(url)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy \(url)")
            }
        }
    }

    @ViewBuilder
    private func connectionLogRow(_ event: ConnectionEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timeFormatter.string(from: event.timestamp))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .leading)

            Text(Self.eventLabel(event.kind))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Self.eventColor(event.kind))
                .frame(width: 90, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.remote)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.vertical, 1)
    }

    private var tailscaleWSURL: String? {
        let url = tailscale.webSocketURL
        return url.isEmpty ? nil : url
    }

    /// The LAN URL helper in `MainWindow.swift` uses the same getifaddrs loop —
    /// we duplicate it here rather than reach across views for a private field.
    /// Cheap enough; runs only on Settings render.
    private static func lanWSURL(port: Int) -> String {
        var address = "localhost"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while let ifa = ptr {
                let sa = ifa.pointee.ifa_addr.pointee
                if sa.sa_family == UInt8(AF_INET) {
                    let name = String(cString: ifa.pointee.ifa_name)
                    if name.hasPrefix("en") {
                        let addr = ifa.pointee.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        let ip = String(cString: inet_ntoa(addr.sin_addr))
                        if ip != "127.0.0.1" {
                            address = ip
                            break
                        }
                    }
                }
                ptr = ifa.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return "ws://\(address):\(port)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func eventLabel(_ kind: ConnectionEvent.Kind) -> String {
        switch kind {
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .authSucceeded: return "Auth ✓"
        case .authFailed: return "Auth ✗"
        case .failed: return "Failed"
        }
    }

    private static func eventColor(_ kind: ConnectionEvent.Kind) -> Color {
        switch kind {
        case .connected, .authSucceeded: return .green
        case .disconnected: return .secondary
        case .authFailed, .failed: return .red
        }
    }
}

// MARK: - Security Tab

private struct SecurityTab: View {
    @Environment(PINManager.self) private var pinManager

    var body: some View {
        Form {
            Section {
                LabeledContent("PIN") {
                    HStack(spacing: 8) {
                        TextField("PIN", text: Bindable(pinManager).pin)
                            .font(.system(size: 24, weight: .medium, design: .monospaced))
                            .frame(minWidth: 180)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: pinManager.pin) {
                                pinManager.savePIN()
                            }

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(pinManager.pin, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy PIN")
                    }
                }

                Button {
                    pinManager.regeneratePIN()
                } label: {
                    Label("Generate New PIN", systemImage: "arrow.clockwise")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Colors Tab

private struct ColorsTab: View {
    @AppStorage("colorNeutral") private var neutralHex: String = "#1E1E1E"
    @AppStorage("colorWaiting") private var waitingHex: String = "#001430"
    @AppStorage("colorSTTActive") private var sttActiveHex: String = "#240040"

    @State private var neutralColor: Color = Color(hex: "#1E1E1E")
    @State private var waitingColor: Color = Color(hex: "#001430")
    @State private var sttActiveColor: Color = Color(hex: "#240040")

    var body: some View {
        Form {
            Section("Terminal Background Colors") {
                Text("These colors are applied to terminal windows based on Claude Code's current state.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ColorPicker(selection: $neutralColor, supportsOpacity: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Neutral")
                            .font(.body.weight(.medium))
                        Text("Claude is actively processing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ColorPicker(selection: $waitingColor, supportsOpacity: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Waiting for Input")
                            .font(.body.weight(.medium))
                        Text("Claude is idle, ready for a prompt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ColorPicker(selection: $sttActiveColor, supportsOpacity: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speech-to-Text Active")
                            .font(.body.weight(.medium))
                        Text("Dictation is in progress")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button("Reset to Defaults") {
                    neutralColor = Color(hex: "#1E1E1E")
                    waitingColor = Color(hex: "#001430")
                    sttActiveColor = Color(hex: "#240040")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Diagnostics Tab

/// Bundle the three log files (`websocket.log`, `push.log`, `kokoro.log`)
/// plus a `system-info.txt` blob into a single zip and surface OS-level
/// share affordances. Replaces the "tail this for me, then this one,
/// then this one" support cycle with a one-tap AirDrop / Mail / Save.
struct DiagnosticsTab: View {
    @State private var lastBundlePath: String?
    @State private var lastError: String?
    @State private var bundling: Bool = false
    /// Anchor view for NSSharingServicePicker — captured by the
    /// AnchoredButton helper below so the picker can attach to the
    /// actual button frame. SwiftUI Buttons don't expose their backing
    /// NSView, hence the AppKit interop.
    @State private var anchorView: NSView?

    var body: some View {
        Form {
            Section {
                LabeledContent("Logs directory") {
                    Text(LogPaths.directory.path)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([LogPaths.directory])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            } header: {
                Text("Log location")
            } footer: {
                Text("Logs survive reboot and are indexed by Console.app under the \"Quip\" filter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                AnchoredButton(anchor: $anchorView) {
                    bundleAndShare()
                } label: {
                    HStack {
                        if bundling {
                            ProgressView().controlSize(.small)
                        }
                        Label("Bundle and share…", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(bundling)

                if let path = lastBundlePath {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.zipper")
                            .foregroundStyle(.green)
                        Text(path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }

                if let err = lastError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Share")
            } footer: {
                Text("Bundles the three log files plus a system-info text blob into a single zip in /tmp, then opens AirDrop / Mail / Messages. The phone-side equivalent (Settings → Diagnostics → Get Mac logs) sends the same bundle over WebSocket.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func bundleAndShare() {
        bundling = true
        lastError = nil
        Task.detached {
            do {
                let zipURL = try DiagnosticsBundle.makeZip()
                await MainActor.run {
                    self.lastBundlePath = zipURL.path
                    self.bundling = false
                    DiagnosticsBundle.presentSharePicker(zipURL: zipURL, anchor: self.anchorView)
                }
            } catch {
                await MainActor.run {
                    self.lastError = "\(error)"
                    self.bundling = false
                }
            }
        }
    }
}

/// SwiftUI Button wrapper that captures the underlying NSView via
/// NSViewRepresentable, so callers can pin an NSSharingServicePicker
/// to the button's frame instead of the whole window.
private struct AnchoredButton<Label: View>: View {
    @Binding var anchor: NSView?
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action, label: label)
            .background(AnchorCapture(anchor: $anchor))
    }

    private struct AnchorCapture: NSViewRepresentable {
        @Binding var anchor: NSView?
        func makeNSView(context: Context) -> NSView {
            let v = NSView(frame: .zero)
            DispatchQueue.main.async { anchor = v }
            return v
        }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }
}
