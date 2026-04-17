// WindowListSidebar.swift
// QuipMac — Sidebar listing managed windows with reorderable rows

import SwiftUI

struct WindowListSidebar: View {
    @Environment(WindowManager.self) private var windowManager
    @Binding var selectedWindowId: String?
    @Binding var windowOrder: [String]

    @State private var showingAddPopover = false
    @State private var newTerminalApp: TerminalApp = .iterm2
    @State private var newProjectDirectory: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            windowList
            Divider()
            bottomBar
        }
        .onAppear { syncWindowOrder() }
        .onChange(of: windowManager.windows.map(\.id)) { _, _ in syncWindowOrder() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Windows")
                .font(.headline)
            Text("(\(orderedWindows.count))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                showingAddPopover.toggle()
            } label: {
                Image(systemName: "plus.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showingAddPopover, arrowEdge: .trailing) {
                addTerminalPopover
            }
            .help("Spawn a new terminal window")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Window List

    private var orderedWindows: [ManagedWindow] {
        let allWindows = windowManager.windows
        var ordered: [ManagedWindow] = []

        // First, add windows in the saved order
        for id in windowOrder {
            if let window = allWindows.first(where: { $0.id == id }) {
                ordered.append(window)
            }
        }

        // Then append any new windows not yet in the order
        for window in allWindows {
            if !windowOrder.contains(window.id) {
                ordered.append(window)
            }
        }

        // Group terminal windows (Terminal.app / iTerm2) at the top. Within each
        // group the user's manual ordering from windowOrder is preserved.
        let terminals = ordered.filter { $0.isTerminal }
        let others = ordered.filter { !$0.isTerminal }
        return terminals + others
    }

    /// Sync windowOrder binding with current window list — called outside of body evaluation
    private func syncWindowOrder() {
        let allWindows = windowManager.windows
        for window in allWindows {
            if !windowOrder.contains(window.id) {
                windowOrder.append(window.id)
            }
        }
        let activeIds = Set(allWindows.map(\.id))
        windowOrder.removeAll { !activeIds.contains($0) }
    }

    private var windowList: some View {
        List(selection: $selectedWindowId) {
            ForEach(Array(orderedWindows.enumerated()), id: \.element.id) { index, window in
                WindowRow(
                    window: window,
                    index: index + 1,
                    isSelected: selectedWindowId == window.id,
                    onToggle: { enabled in
                        windowManager.toggleWindow(window.id, enabled: enabled)
                    },
                    onMoveUp: index > 0 ? {
                        let id = window.id
                        if let idx = windowOrder.firstIndex(of: id), idx > 0 {
                            windowOrder.swapAt(idx, idx - 1)
                        }
                    } : nil,
                    onMoveDown: index < orderedWindows.count - 1 ? {
                        let id = window.id
                        if let idx = windowOrder.firstIndex(of: id), idx < windowOrder.count - 1 {
                            windowOrder.swapAt(idx, idx + 1)
                        }
                    } : nil
                )
                .tag(window.id)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button {
                showingAddPopover.toggle()
            } label: {
                Label("Add", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            Button {
                removeSelectedWindow()
            } label: {
                Label("Remove", systemImage: "minus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(selectedWindowId == nil)

            Spacer()

            Button {
                windowManager.refreshWindowList()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Refresh window list")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Add Terminal Popover

    private var addTerminalPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Terminal")
                .font(.headline)

            Picker("Terminal App", selection: $newTerminalApp) {
                ForEach(TerminalApp.allCases) { app in
                    Text(app.rawValue).tag(app)
                }
            }
            .pickerStyle(.radioGroup)

            VStack(alignment: .leading, spacing: 4) {
                Text("Project Directory")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("~/Projects/my-project", text: $newProjectDirectory)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 200)

                    Button {
                        chooseDirectory()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showingAddPopover = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Open") {
                    spawnTerminal()
                    showingAddPopover = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newProjectDirectory.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Actions

    private func removeSelectedWindow() {
        guard let id = selectedWindowId else { return }
        windowManager.toggleWindow(id, enabled: false)
        windowOrder.removeAll { $0 == id }
        selectedWindowId = nil
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project directory"

        if panel.runModal() == .OK, let url = panel.url {
            newProjectDirectory = url.path
        }
    }

    private func spawnTerminal() {
        let dir = newProjectDirectory
        let appName = newTerminalApp.rawValue
        let script: String

        switch newTerminalApp {
        case .terminal:
            script = """
            tell application "\(appName)"
                activate
                do script "cd \(dir)"
            end tell
            """
        case .iterm2:
            script = """
            tell application "\(appName)"
                activate
                tell current window
                    create tab with default profile
                    tell current session
                        write text "cd \(dir)"
                    end tell
                end tell
            end tell
            """
        }

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }

        // Refresh after a brief delay to pick up the new window
        Task {
            try? await Task.sleep(for: .seconds(1))
            windowManager.refreshWindowList()
        }
    }
}

// MARK: - Window Row

private struct WindowRow: View {
    let window: ManagedWindow
    let index: Int
    let isSelected: Bool
    let onToggle: (Bool) -> Void
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?

    @State private var isHovering = false

    /// Checkbox reads directly from the live ManagedWindow and writes through
    /// the onToggle callback. We used to mirror `window.isEnabled` into a
    /// local @State that was only seeded at init — so when the phone (or an
    /// auto-enable triggered by mirror-desktop's tap-to-activate) flipped a
    /// window on, this sidebar stayed visually out of sync. Direct binding
    /// keeps the checkbox honest no matter who changed the state.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { window.isEnabled },
            set: { onToggle($0) }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: enabledBinding) {
                EmptyView()
            }
            .toggleStyle(.checkbox)

            Text("\(index).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)

            Circle()
                .fill(Color(hex: window.assignedColor))
                .frame(width: 10, height: 10)

            if let icon = window.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }

            VStack(alignment: .leading, spacing: 1) {
                // Primary label: folder/project when known, else app name.
                // Rendered in the window's palette color and bold so it's
                // visually distinctive and consistent with the iOS tile.
                Text(window.subtitle.isEmpty ? window.app : window.subtitle)
                    .font(.body.weight(.bold))
                    .foregroundStyle(Color(hex: window.assignedColor))
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Secondary label: app name when a folder sits above it;
                // otherwise the window title so non-terminal windows still
                // show something descriptive.
                Text(window.subtitle.isEmpty ? window.name : window.app)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isHovering {
                HStack(spacing: 2) {
                    if let onMoveUp {
                        Button { onMoveUp() } label: {
                            Image(systemName: "chevron.up")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                    }
                    if let onMoveDown {
                        Button { onMoveDown() } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .opacity(window.isEnabled ? 1.0 : 0.5)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

