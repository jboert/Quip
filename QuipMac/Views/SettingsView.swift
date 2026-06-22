// SettingsView.swift
// QuipMac — macOS Settings window with tabbed configuration panels

import SwiftUI
import Darwin
import CoreImage
import AppKit

/// The six Settings panes. Single source of truth for the customizable
/// NSToolbar (id / title / SF Symbol) and the content switch below.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, layouts, projects, prompts, connection, security, notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:       return "General"
        case .layouts:       return "Layouts"
        case .projects:      return "Projects"
        case .prompts:       return "Prompts"
        case .connection:    return "Connection"
        case .security:      return "Security"
        case .notifications: return "Notifications"
        }
    }

    var systemImage: String {
        switch self {
        case .general:       return "gearshape.fill"
        case .layouts:       return "rectangle.3.group.fill"
        case .projects:      return "folder.fill"
        case .prompts:       return "text.bubble.fill"
        case .connection:    return "wifi"
        case .security:      return "lock.fill"
        case .notifications: return "bell.badge.fill"
        }
    }

    /// Sidebar icon-tile tint. Restrained, System-Settings-style mapping — one
    /// flat color per pane, semantically chosen (green = connectivity, orange =
    /// security, red = alerts) rather than decorative.
    var tint: Color {
        switch self {
        case .general:       return .gray
        case .layouts:       return .indigo
        case .projects:      return .blue
        case .prompts:       return .purple
        case .connection:    return .green
        case .security:      return .orange
        case .notifications: return .red
        }
    }
}

struct SettingsView: View {
    @Environment(WindowManager.self) private var windowManager
    @Environment(WebSocketServer.self) private var webSocketServer
    @Environment(BonjourAdvertiser.self) private var bonjourAdvertiser
    @Environment(PINManager.self) private var pinManager

    // Persisted sidebar selection so reopening Settings lands on the last pane.
    @AppStorage("settingsSelectedTab") private var selectionRaw: String = SettingsTab.general.id

    private var current: SettingsTab { SettingsTab(rawValue: selectionRaw) ?? .general }

    /// List(selection:) wants an optional binding; bridge it to the persisted
    /// raw string. Ignores nil (clicking empty space) so a pane is always shown.
    private var selection: Binding<SettingsTab?> {
        Binding(
            get: { current },
            set: { if let new = $0 { selectionRaw = new.id } }
        )
    }

    var body: some View {
        // Sidebar layout — the modern macOS System Settings idiom. A
        // NavigationSplitView fills a resizable window far better than a
        // top-anchored TabView/form (no oceans of dead space when the window
        // grows), and reads as a native Apple app. Every .environment injected
        // on this scene in QuipMacApp reaches each pane unchanged.
        NavigationSplitView {
            List(SettingsTab.allCases, selection: selection) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    SettingsIconTile(symbol: tab.systemImage, tint: tab.tint)
                }
                .tag(tab)
                .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(min: 198, ideal: 214, max: 264)
        } detail: {
            paneContent
                // Cap the content column so panes never sprawl edge-to-edge
                // when the window is widened — the System Settings move. Rows
                // stay readable (no label-far-left / value-far-right chasm);
                // extra width becomes quiet margin. The second frame re-centers
                // that capped column in the detail pane.
                .frame(maxWidth: 600, maxHeight: .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(current.title)
        }
        // min = floor; ideal = the size the window opens at when there's no
        // saved frame. Without an ideal, the NavigationSplitView + grouped
        // forms drove the window to a sprawling ~1200×1100; 780×600 is a tidy
        // default that still resizes freely (the original vertical-resize fix).
        .frame(minWidth: 720, idealWidth: 780, maxWidth: .infinity,
               minHeight: 480, idealHeight: 600, maxHeight: .infinity)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch current {
        case .general:       GeneralTab()
        case .layouts:       LayoutsTab()
        case .projects:      ProjectsTab()
        case .prompts:       PromptsTab()
        case .connection:    ConnectionTab()
        case .security:      SecurityTab()
        case .notifications: NotificationsTab()
        }
    }
}

// MARK: - Sidebar icon tile
//
// SF Symbol in white on a small tinted rounded square — the System Settings
// sidebar idiom. Deliberately restrained (one flat tint, no gradient, no
// shadow) so it reads as native macOS rather than decorative AI filler.
private struct SettingsIconTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - Shared status vocabulary
//
// One consistent way to render "is it on / granted / set?" across every
// tab. Before this, the same idea showed up three different ways: a Circle
// dot (Connection), a bare SF checkmark (Permissions), or plain colored
// text (Notifications). StatusDot unifies them into a single tinted glyph +
// label so the whole window speaks one language.
private struct StatusDot: View {
    enum Kind { case ok, bad, warn, neutral, busy }

    let kind: Kind
    let text: String
    var mono: Bool = false

    private var glyph: String {
        switch kind {
        case .ok:      return "checkmark.circle.fill"
        case .bad:     return "xmark.circle.fill"
        case .warn:    return "exclamationmark.triangle.fill"
        case .neutral: return "circle.fill"
        case .busy:    return "hourglass"
        }
    }

    private var tint: Color {
        switch kind {
        case .ok:      return .green
        case .bad:     return .red
        case .warn:    return .orange
        case .neutral: return .secondary
        case .busy:    return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: glyph)
                .foregroundStyle(tint)
                .imageScale(.medium)
            Text(text)
                .font(mono ? .body.monospaced() : .body)
        }
    }
}

// MARK: - Notifications Tab

/// Collects the APNs auth-key configuration (.p8 file, Key ID, Team ID,
/// Bundle ID) + a Test Push button. The .p8 goes into the Keychain via
/// APNsKeyStore; the three ID fields sit in the Keychain via
/// APNsMetadataStore. No pushes fire from here — the only send is Test
/// Push, which loops registered devices and reports per-device
/// success/failure inline.
private struct NotificationsTab: View {
    @Environment(PushNotificationService.self) private var pushService

    // GH #22 — moved from @AppStorage("apnsKeyId" / "apnsTeamId" / "apnsBundleId")
    // to APNsMetadataStore (Keychain). View holds @State copies for SwiftUI's
    // two-way TextField binding; each is seeded once at init from the store
    // below (the first read performs the one-shot migration from UserDefaults
    // if needed), and .onChange writes back. importKey() also writes the store
    // directly when it auto-syncs the Key ID. The bundleId default flows
    // through the store (com.quip.QuipiOS).
    @State private var keyId: String = APNsMetadataStore.keyId
    @State private var teamId: String = APNsMetadataStore.teamId
    @State private var bundleId: String = APNsMetadataStore.bundleId

    @State private var hasKey: Bool = APNsKeyStore.hasKey
    @State private var importStatus: String?
    @State private var testStatus: [String] = []
    @State private var isSending: Bool = false
    @State private var showForgetAllConfirm: Bool = false

    var body: some View {
        Form {
            Section("APNs Auth Key") {
                LabeledContent("Auth key") {
                    HStack(spacing: 8) {
                        StatusDot(kind: hasKey ? .ok : .bad,
                                  text: hasKey ? "Stored in Keychain" : "Not set")
                        Spacer()
                        Button(hasKey ? "Replace .p8…" : "Import .p8…") { importKey() }
                        if hasKey {
                            Button("Clear") { clearKey() }
                        }
                    }
                }
                if let importStatus {
                    Text(importStatus)
                        .font(.caption)
                        .foregroundStyle(importStatus.hasPrefix("Error") ? .red : .secondary)
                }
                TextField("Key ID", text: $keyId)
                    .onChange(of: keyId) { _, new in APNsMetadataStore.keyId = new }
                TextField("Team ID", text: $teamId)
                    .onChange(of: teamId) { _, new in APNsMetadataStore.teamId = new }
                TextField("Bundle ID", text: $bundleId)
                    .onChange(of: bundleId) { _, new in APNsMetadataStore.bundleId = new }
            }

            Section("Registered Devices (\(pushService.devices.count))") {
                if pushService.devices.isEmpty {
                    Text("No iPhones have registered yet. Open Quip on the phone and connect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pushService.devices, id: \.token) { device in
                        HStack(spacing: 8) {
                            Image(systemName: "iphone")
                                .foregroundStyle(.secondary)
                            Text(device.token.prefix(12) + "…")
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Text(device.environment)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(role: .destructive) {
                        showForgetAllConfirm = true
                    } label: {
                        Label("Forget All Devices", systemImage: "trash")
                    }
                    .confirmationDialog(
                        "Forget all \(pushService.devices.count) registered devices?",
                        isPresented: $showForgetAllConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Forget All", role: .destructive) {
                            pushService.removeAllDevices()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Clears stale tokens left by app reinstalls. Each phone re-registers a fresh token the next time it connects.")
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
        .formStyle(.grouped)
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
                    var status = "Imported \(url.lastPathComponent)"
                    // The Key ID can't be derived from the key bytes, so a
                    // mismatched kid silently passes import and only fails at
                    // send time with `InvalidProviderToken`. Apple's filename
                    // (`AuthKey_<KEYID>.p8`) carries the kid — sync it to the
                    // stored key so the two can't drift apart.
                    if let fileKeyId = APNsMetadataStore.keyId(fromFilename: url.lastPathComponent) {
                        if fileKeyId != keyId {
                            let old = keyId
                            // Write the store directly, not just @State: production
                            // push paths (PushNotificationService) read
                            // APNsMetadataStore.keyId from Keychain, so persistence
                            // must not hinge on the Key ID TextField's deferred
                            // .onChange firing on a later SwiftUI render.
                            APNsMetadataStore.keyId = fileKeyId
                            keyId = fileKeyId
                            status += old.isEmpty
                                ? " · Key ID set to \(fileKeyId)"
                                : " · Key ID \(old)→\(fileKeyId) to match the file"
                        }
                    } else if !keyId.isEmpty {
                        // Filename carries no Key ID (renamed/duplicated file,
                        // e.g. "AuthKey_… 2.p8" or "prod-key.p8") and a kid is
                        // already set — it may now name the WRONG key. The kid
                        // isn't recoverable from the key bytes, so warn instead
                        // of letting the stale kid reach APNs as a silent
                        // InvalidProviderToken at send time.
                        status += " · ⚠︎ couldn't read Key ID from filename — verify Key ID “\(keyId)” matches this key"
                    }
                    importStatus = status
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

// MARK: - Projects Tab
//
// Consolidates the former Directories, swrm, and Prompts tabs into one
// grouped Form with three sections. Each retains its own backing store and
// add/remove flow — only the chrome merged:
//   • Spawn Directories — UserDefaults "projectDirectories"
//   • swrm Watched Roots — SwrmProjectStore (UserDefaults "swrmProjectRoots")
//   • Prompt Library — PromptLibrary (FS-backed, broadcasts to phones on change)

private struct ProjectsTab: View {
    // Spawn directories
    @AppStorage("projectDirectories") private var directoriesData: Data = Data()
    @State private var directories: [String] = []

    // swrm roots
    @Environment(SwrmProjectStore.self) private var swrm
    @State private var swrmAddError: String?

    var body: some View {
        Form {
            spawnDirectoriesSection
            swrmSection
        }
        .formStyle(.grouped)
        .onAppear { loadDirectories() }
    }

    // MARK: Spawn directories

    @ViewBuilder
    private var spawnDirectoriesSection: some View {
        Section {
            if directories.isEmpty {
                Text("No directories yet. Add folders to quickly spawn new terminal sessions from the phone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(directories, id: \.self) { dir in
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                        Text(dir)
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
            Button { addDirectory() } label: {
                Label("Add Directory…", systemImage: "plus")
            }
        } header: {
            Text("Spawn Directories (\(directories.count))")
        } footer: {
            Text("Roots offered when the phone spawns a new terminal session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

    // MARK: swrm roots

    @ViewBuilder
    private var swrmSection: some View {
        Section {
            if swrm.roots.isEmpty {
                Text("Add a swrm project root to get a phone card, push, and a terminal notice when one of its stories moves to In Progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(swrm.roots, id: \.self) { root in
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((root as NSString).lastPathComponent)
                                .font(.body)
                            Text(root)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            swrm.remove(path: root)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            if let swrmAddError {
                Text(swrmAddError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button { addSwrmRoot() } label: {
                Label("Add Project…", systemImage: "plus")
            }
        } header: {
            Text("swrm Watched Roots (\(swrm.roots.count))")
        } footer: {
            Text("Each root is tailed live — add or remove without restarting Quip.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addSwrmRoot() {
        swrmAddError = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a swrm project root (the folder that contains, or will contain, .swrm/)"

        if panel.runModal() == .OK, let url = panel.url {
            if let error = swrm.add(path: url.path) {
                swrmAddError = error.localizedDescription
            }
        }
    }

}

// MARK: - Prompts Tab
//
// The prompt library gets its own pane (split out of Projects — prompts are
// text snippets, not project folders). A grouped Form of PromptRows + New /
// Reveal. Editing happens in PromptEditorSheet; writes flow through
// PromptLibrary.put, which triggers the FS-watcher broadcast to every
// connected phone.

private struct PromptsTab: View {
    @Environment(PromptLibrary.self) private var library
    @State private var editingPrompt: PromptEntry?
    @State private var creatingPrompt = false

    var body: some View {
        Form {
            Section {
                if library.entries.isEmpty {
                    Text("No prompts yet. Click + to create one, or drop .txt files into ~/Library/Application Support/Quip/prompts/.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(library.entries) { entry in
                        PromptRow(
                            entry: entry,
                            onEdit: { editingPrompt = entry },
                            onDelete: { library.delete(id: entry.id) }
                        )
                    }
                }
                HStack(spacing: 12) {
                    Button { creatingPrompt = true } label: {
                        Label("New Prompt…", systemImage: "plus")
                    }
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([PromptLibrary.directory])
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            } header: {
                Text("Prompt Library (\(library.entries.count))")
            } footer: {
                Text("Tapped on the phone, the body is sent verbatim to the active terminal. Edits broadcast to every connected phone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $creatingPrompt) {
            PromptEditorSheet(initial: nil) { id, label, body in
                _ = library.put(id: id, label: label, body: body)
            }
        }
        .sheet(item: $editingPrompt) { entry in
            PromptEditorSheet(initial: entry) { id, label, body in
                _ = library.put(id: id, label: label, body: body)
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
    @AppStorage("crashRecoveryEnabled") private var crashRecoveryEnabled = false
    @State private var crashRecoveryError: String?

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
                Text("If System Settings already shows Quip enabled but the row stays red, turn Quip off and back on there. Screen Recording changes may require relaunching Quip.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Terminal") {
                Picker("Default Terminal App", selection: $defaultTerminalApp) {
                    ForEach(TerminalApp.allCases) { app in
                        Text(app.rawValue).tag(app.rawValue)
                    }
                }
            }

            // Folded in from the former Colors tab — terminal background tints
            // keyed to Claude Code's state. Lives in its own struct so its
            // @AppStorage + @State color bindings stay self-contained.
            TerminalColorsSection()

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle("Show in menu bar", isOn: $showInMenuBar)
                Toggle("Show in Dock", isOn: $showInDock)
            }

            Section("Reliability") {
                Toggle("Auto-restart on crash", isOn: Binding(
                    get: { crashRecoveryEnabled },
                    set: { applyCrashRecoveryToggle($0) }
                ))
                Text("If Quip crashes, macOS launchd relaunches it after 30s. Cmd+Q and normal quits do not trigger relaunch. Installs ~/Library/LaunchAgents/\(CrashRecoveryAgent.label).plist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let err = crashRecoveryError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
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

    /// Wires the Reliability toggle: write AppStorage + invoke install/uninstall.
    /// Failures revert the toggle and surface the error inline so the user sees
    /// why launchd refused (typically: SIP-protected path, missing LaunchAgents
    /// directory permissions, or a malformed plist payload).
    private func applyCrashRecoveryToggle(_ newValue: Bool) {
        crashRecoveryError = nil
        do {
            if newValue {
                try CrashRecoveryAgent.install()
            } else {
                try CrashRecoveryAgent.uninstall()
            }
            crashRecoveryEnabled = newValue
        } catch {
            crashRecoveryError = "Could not \(newValue ? "install" : "remove") crash-recovery agent: \(error.localizedDescription)"
            // Leave AppStorage unchanged — toggle visually reverts.
        }
    }

    @ViewBuilder
    private func whisperStatusRow() -> some View {
        // Mirror the StatusDot look: tinted glyph + label + tail detail. No
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
    /// pane via an x-apple.systempreferences URL — no nav required. The
    /// leading glyph matches StatusDot's vocabulary (green check / red x).
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
        guard let url = pane.systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Terminal background tints keyed to Claude Code's state. A self-contained
/// `Section` (folded in from the former Colors tab) so it drops straight into
/// the General Form. Keeps its own @AppStorage hex + @State Color bindings.
private struct TerminalColorsSection: View {
    @AppStorage("colorNeutral") private var neutralHex: String = "#1E1E1E"
    @AppStorage("colorWaiting") private var waitingHex: String = "#001430"
    @AppStorage("colorSTTActive") private var sttActiveHex: String = "#240040"

    @State private var neutralColor: Color = Color(hex: "#1E1E1E")
    @State private var waitingColor: Color = Color(hex: "#001430")
    @State private var sttActiveColor: Color = Color(hex: "#240040")

    var body: some View {
        Section {
            ColorPicker(selection: $neutralColor, supportsOpacity: false) {
                colorLabel("Neutral", "Claude is actively processing")
            }
            ColorPicker(selection: $waitingColor, supportsOpacity: false) {
                colorLabel("Waiting for Input", "Claude is idle, ready for a prompt")
            }
            ColorPicker(selection: $sttActiveColor, supportsOpacity: false) {
                colorLabel("Speech-to-Text Active", "Dictation is in progress")
            }
            Button("Reset to Defaults") {
                neutralColor = Color(hex: "#1E1E1E")
                waitingColor = Color(hex: "#001430")
                sttActiveColor = Color(hex: "#240040")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } header: {
            Text("Terminal Colors")
        } footer: {
            Text("Applied to terminal windows based on Claude Code's current state.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func colorLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body.weight(.medium))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
                    StatusDot(kind: webSocketServer.isRunning ? .ok : .bad,
                              text: webSocketServer.isRunning ? "Running" : "Stopped")
                }

                LabeledContent("Connected Clients") {
                    Text("\(webSocketServer.connectedClientCount)")
                        .monospacedDigit()
                }

                TextField("Port", value: $port, format: .number)
                    .frame(width: 100)
            }

            // §B5 per-client visibility — full table of every active socket so
            // "is anyone actually talking to me?" answers from a glance instead
            // of a `netstat | grep 8765` ritual.
            Section("Connected Clients") {
                let clients: [WebSocketServer.ConnectedClientInfo] = webSocketServer.connectedClients
                if clients.isEmpty {
                    Text("None — server is listening but no client has connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(clients) { (c: WebSocketServer.ConnectedClientInfo) in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: clientIcon(c))
                                    .foregroundStyle(c.isAuthenticated ? .green : .yellow)
                                Text(c.displayTitle).font(.body.weight(.medium))
                                Spacer()
                                Text(c.isAuthenticated ? "authed" : "awaiting auth")
                                    .font(.caption)
                                    .foregroundStyle(c.isAuthenticated ? Color.secondary : Color.orange)
                            }
                            HStack(spacing: 12) {
                                Text(c.remote)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                if let kind = c.deviceKind {
                                    Text(kind)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Text("connected \(Self.relTime.localizedString(for: c.connectedAt, relativeTo: Date()))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text("· last \(Self.relTime.localizedString(for: c.lastActivity, relativeTo: Date()))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Bonjour Discovery") {
                LabeledContent("Status") {
                    StatusDot(kind: bonjourAdvertiser.isAdvertising ? .ok : .bad,
                              text: bonjourAdvertiser.isAdvertising ? "Advertising" : "Stopped")
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
                TextField("Claude command", text: $spawnCommand)
                    .textFieldStyle(.roundedBorder)
                Text("Used when the phone selects Claude. Codex runs `codex`; Terminal opens a bare shell.")
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

    private static let relTime: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func clientIcon(_ c: WebSocketServer.ConnectedClientInfo) -> String {
        switch c.deviceKind {
        case "ios": return "iphone"
        case "watchos": return "applewatch"
        case "linux": return "desktopcomputer"
        case "mac": return "laptopcomputer"
        default: return "iphone"
        }
    }
}

// MARK: - Security Tab

private struct SecurityTab: View {
    @Environment(PINManager.self) private var pinManager
    @Environment(WebSocketServer.self) private var webSocketServer
    @Environment(CloudflareTunnel.self) private var tunnel
    @Environment(TailscaleService.self) private var tailscale

    // The pairing URL must match wherever the phone actually connects, so
    // we branch on the same mode the user picked in the Connection tab.
    @AppStorage("networkMode") private var networkModeRaw: String = NetworkMode.cloudflareTunnel.rawValue

    private var networkMode: NetworkMode {
        NetworkMode(rawValue: networkModeRaw) ?? .cloudflareTunnel
    }

    // Diagnostics-bundle state — folded in from the former Diagnostics
    // tab. Co-located with PIN + pairing here because both topics are
    // about "what does this Mac expose to phones, and what shows up in
    // logs about that exposure?" Single tab keeps the auth-and-audit
    // story in one place.
    @State private var lastBundlePath: String?
    @State private var lastError: String?
    @State private var bundling: Bool = false
    @State private var anchorView: NSView?
    // Separate anchor for the "Send to iPhone" pairing-link share picker so it
    // pins to its own button, not the diagnostics "Bundle and share…" one.
    @State private var pairingAnchorView: NSView?

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

            Section {
                pairingQRBlock

                AnchoredButton(anchor: $pairingAnchorView) {
                    sharePairingLink()
                } label: {
                    Label("Send to iPhone…", systemImage: "square.and.arrow.up")
                }
                .disabled(pairingURL().isEmpty)
            } header: {
                Text("Pair iPhone")
            } footer: {
                Text("The iPhone Camera app can’t open this QR (it shows “No usable data found”). Scan it inside the Quip app — qrcode.viewfinder button in the URL bar — to auto-fill the URL and PIN, no typing. Or tap “Send to iPhone” to AirDrop / Message / Mail a quip://pair link the phone taps to pair, no scan needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                Text("Diagnostics — log location")
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
                Text("Diagnostics — share")
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

    /// Share the pairing link so a remote phone can tap-to-pair without the
    /// QR or the native Camera. Mirrors the diagnostics-share pattern
    /// (NSSharingServicePicker pinned to an AnchoredButton): a tappable
    /// quip://pair?url=…&pin=… link plus a plaintext "<ws url>\nPIN: <pin>"
    /// fallback for share targets that ignore custom-scheme URLs.
    @MainActor
    private func sharePairingLink() {
        let url = pairingURL()
        guard !url.isEmpty else { return }
        let payload = PairingPayload(url: url, pin: pinManager.pin)
        var items: [Any] = []
        if let encoded = payload.encodedURL(), let link = URL(string: encoded) {
            items.append(link)
        }
        items.append("\(url)\nPIN: \(pinManager.pin)")
        let picker = NSSharingServicePicker(items: items)
        if let anchor = pairingAnchorView {
            picker.show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
        } else if let window = NSApp.keyWindow,
                  let contentView = window.contentView {
            picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        }
    }

    /// Renders a pairing QR for whichever URL is currently most useful: the
    /// Cloudflare tunnel URL (cross-network) when up, otherwise the local
    /// Bonjour/IP URL the iPhone can reach over LAN. Re-renders whenever
    /// the tunnel resolves a new URL or the PIN regenerates — no manual
    /// refresh button needed because the views are bound to @Observable
    /// state.
    @ViewBuilder
    private var pairingQRBlock: some View {
        let currentURL = pairingURL()
        if currentURL.isEmpty {
            Text("Start the WebSocket server to display a pairing QR.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let payload = PairingPayload(url: currentURL, pin: pinManager.pin)
            VStack(alignment: .leading, spacing: 8) {
                Text("Scan in the Quip app — the Camera app can’t open it")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 16) {
                    if let encoded = payload.encodedURL(),
                       let qr = Self.qrImage(for: encoded) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 160, height: 160)
                            .background(Color.white)
                            .cornerRadius(6)
                    } else {
                        Color.secondary.frame(width: 160, height: 160).cornerRadius(6)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("URL")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(currentURL)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        Text("PIN")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        Text(pinManager.pin)
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Embed the URL the iPhone will actually reach, branching on the active
    /// network mode so a Tailscale-mode link carries the stable ts.net / 100.x
    /// address instead of a useless ws://<host>.local. Mirrors the per-mode URL
    /// sources surfaced in ConnectionTab's "Diagnostics — Connection URLs" rows:
    ///   .tailscale        → TailscaleService.webSocketURL (ts.net / 100.x)
    ///   .cloudflareTunnel → tunnel.webSocketURL (works on cellular too)
    ///   .localOnly        → LAN ws://<host>.local:port
    /// Empty when the chosen mode has no URL yet (server stopped, or
    /// tunnel/Tailscale not resolved) — the QR block shows a "start the server"
    /// hint in that case.
    private func pairingURL() -> String {
        switch networkMode {
        case .tailscale:
            return tailscale.webSocketURL
        case .cloudflareTunnel:
            return tunnel.webSocketURL
        case .localOnly:
            guard webSocketServer.isRunning else { return "" }
            let host = Host.current().localizedName ?? "localhost"
            return "ws://\(host).local:8765"
        }
    }

    /// Render the payload string into an NSImage via CIFilter (no third-
    /// party QR library). errorCorrection=M balances density vs. resilience
    /// to phone-camera blur. Output is upscaled with nearest-neighbor in
    /// the SwiftUI Image to keep edges crisp at display size.
    private static func qrImage(for content: String) -> NSImage? {
        guard let data = content.data(using: .utf8) else { return nil }
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(data, forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter?.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: ciImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
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

// MARK: - Prompt Row
//
// Single row in the Prompt Library section. Hover reveals inline pencil +
// trash buttons (so you can edit / delete without first selecting a row).
// Right-click anywhere opens a context menu with Edit / Delete / Reveal in
// Finder. Double-click also edits — three discoverability paths, pick the
// one that fits muscle memory.
private struct PromptRow: View {
    let entry: PromptEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.label)
                        .font(.system(size: 13, weight: .medium))
                    if entry.label != entry.id {
                        Text(entry.id)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(entry.bodyPreview)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()

            // Hover-revealed quick actions. Opacity hides them rather than
            // conditional inclusion so layout stays stable when the cursor
            // crosses row boundaries (no row-height jitter).
            HStack(spacing: 4) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
            .opacity(hovering ? 1 : 0)

            Text("\(entry.bodyBytes) B")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Edit", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
            Divider()
            Button("Reveal in Finder") {
                let url = PromptLibrary.directory.appendingPathComponent("\(entry.id).txt")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

// MARK: - Prompt Editor Sheet (Mac)
//
// Form-style editor matching the iOS PromptEditorSheet. `initial=nil`
// = new prompt (id editable); non-nil = edit (id locked because the
// id IS the filename — renaming would orphan keystroke bindings on
// the phone). Save fires `onSave(id, label, body)`; caller writes
// through PromptLibrary.put which triggers the FS-watcher broadcast.

private struct PromptEditorSheet: View {
    let initial: PromptEntry?
    let onSave: (_ id: String, _ label: String, _ body: String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var idText: String = ""
    @State private var labelText: String = ""
    @State private var bodyText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(initial == nil ? "New prompt" : "Edit prompt")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Id (filename)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. ship-it", text: $idText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(initial != nil)
                Text(initial == nil
                     ? "Allowed: letters, digits, dash, underscore, dot. Spaces become dashes."
                     : "Id can't be changed after creation — would orphan phone-side bindings. Delete and recreate to rename.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Label (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Display label — defaults to id if empty", text: $labelText)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Body")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(bodyText.utf8.count) B")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                TextEditor(text: $bodyText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                Text("Sent verbatim to the active terminal when the row is tapped on the phone. No template expansion.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            if let initial {
                idText = initial.id
                labelText = initial.label == initial.id ? "" : initial.label
                bodyText = initial.body
            }
        }
    }

    private var canSave: Bool {
        !idText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let id = idText.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = labelText.trimmingCharacters(in: .whitespaces)
        let body = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !body.isEmpty else { return }
        onSave(id, label.isEmpty ? id : label, body)
        dismiss()
    }
}
