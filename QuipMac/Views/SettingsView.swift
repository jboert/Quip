// SettingsView.swift
// QuipMac — macOS Settings window with tabbed configuration panels

import SwiftUI

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
        }
        .frame(width: 520, height: 400)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @AppStorage("defaultTerminalApp") private var defaultTerminalApp: String = TerminalApp.terminal.rawValue
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @AppStorage("showInDock") private var showInDock = true

    var body: some View {
        Form {
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

            Section("Window Refresh") {
                Text("Windows are automatically refreshed when the app activates and when displays change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

    @AppStorage("wsPort") private var port: Int = 8765
    @AppStorage("bonjourServiceName") private var serviceName: String = "Quip"
    @AppStorage("localOnlyMode") private var localOnlyMode = false
    @AppStorage("requirePINForLocal") private var requirePINForLocal = false
    @State private var logEntries: [String] = []

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
                Toggle("Local only (no Cloudflare tunnel)", isOn: $localOnlyMode)

                if localOnlyMode {
                    Toggle("Require PIN for local connections", isOn: $requirePINForLocal)
                        .padding(.leading, 16)
                }

                Text(localOnlyMode
                    ? "Clients must be on the same network. QR code shows local address."
                    : "Cloudflare tunnel enables connections from anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Connection Log") {
                if logEntries.isEmpty {
                    Text("No recent activity")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(logEntries, id: \.self) { entry in
                                Text(entry)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 100)
                }
            }
        }
        .formStyle(.grouped)
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
