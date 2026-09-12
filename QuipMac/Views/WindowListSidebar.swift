// WindowListSidebar.swift
// QuipMac — Sidebar listing managed windows with reorderable rows

import SwiftUI

struct WindowListSidebar: View {
    @Environment(WindowManager.self) private var windowManager
    @Environment(TerminalStateDetector.self) private var stateDetector
    @Environment(OutputActivityTracker.self) private var outputActivity
    @Binding var selectedWindowId: String?

    /// Which window kinds the wand switches on, and which orders it rotates
    /// through. Both were hardcoded; see `WandTargetKinds` for why the old
    /// hardcoding meant a wand tap could never select the iTerm2 windows alone.
    @AppStorage("wandTargetKinds") private var wandTargetKindsRaw: Int = WandTargetKinds.default.rawValue
    @AppStorage("wandSortModes") private var wandSortModesRaw: String = WandSortMode.stored(WandSortMode.allCases)
    /// Where the rotation stands. Persisted so the wand does not silently
    /// restart at "Dev" on every launch while the header still reads the mode
    /// from the last session.
    @AppStorage("wandSortModeIndex") private var wandSortModeIndex: Int = 0

    @State private var showingAddPopover = false
    @State private var newTerminalApp: TerminalApp = .iterm2
    @State private var newProjectDirectory: String = ""

    var body: some View {
        let snapshot = sidebarSnapshot()

        VStack(spacing: 0) {
            header(count: snapshot.rows.count)
            Divider()
            windowList(snapshot: snapshot)
            Divider()
            bottomBar
        }
    }

    // MARK: - Header

    private func header(count: Int) -> some View {
        HStack {
            Text("Windows")
                .font(.headline)
            Text("(\(count))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                // Option-click keeps the "turn everything off" the rotation
                // took away. It was the old second tap, which is exactly why a
                // double-click used to end with nothing selected.
                if NSEvent.modifierFlags.contains(.option) {
                    disableAllTargets()
                } else {
                    magicSort()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "wand.and.stars")
                        .font(.title3)
                    // Without this the rotation is invisible and the button is
                    // back to doing something the user cannot predict.
                    Text(currentWandMode.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Sort windows: \(currentWandMode.label)")
            .help("Sort + switch on your windows — \(currentWandMode.help). "
                  + "Click again for the next order. Option-click to switch them all off. "
                  + "Configure in Settings → General.")

            Button {
                showingAddPopover.toggle()
            } label: {
                Image(systemName: "plus.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add a terminal")
            .popover(isPresented: $showingAddPopover, arrowEdge: .trailing) {
                addTerminalPopover
            }
            .help("Spawn a new terminal window")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Window List

    private struct SidebarSnapshot {
        let rows: [SidebarRowModel]
    }

    private struct SidebarRowModel: Identifiable {
        let window: ManagedWindow
        /// Arrange slot — the position this window gets when you hit Arrange,
        /// counted over *enabled* windows only. `nil` for a disabled window,
        /// which is not in the layout at all.
        let slot: Int?
        let previousSameRankID: String?
        let nextSameRankID: String?

        var id: String { window.id }
    }

    private func sidebarSnapshot() -> SidebarSnapshot {
        let ordered = orderedWindows()
        // Row numbers used to count every row, which read as "Arrange puts this
        // one third" — wrong, because Arrange only places enabled windows. Number
        // the enabled ones in order and leave the rest blank, so the number on a
        // row means exactly one thing.
        var nextSlot = 0
        var slotByID: [String: Int] = [:]
        for window in ordered where window.isEnabled {
            nextSlot += 1
            slotByID[window.id] = nextSlot
        }
        let rows = ordered.enumerated().map { index, window in
            let rank = windowTier(window)
            let nextIndex = ordered.index(after: index)
            let previousID = index > ordered.startIndex && windowTier(ordered[index - 1]) == rank
                ? ordered[index - 1].id
                : nil
            let nextID = ordered.indices.contains(nextIndex) && windowTier(ordered[nextIndex]) == rank
                ? ordered[nextIndex].id
                : nil

            return SidebarRowModel(
                window: window,
                slot: slotByID[window.id],
                previousSameRankID: previousID,
                nextSameRankID: nextID
            )
        }
        return SidebarSnapshot(rows: rows)
    }

    /// `WindowManager.windows` is already stored in `customOrder` sequence —
    /// one list, written only through `setOrder`, so the sidebar, the layout
    /// preview, and Arrange can never disagree about position again. Windows
    /// that appeared since the last snapshot are already appended by
    /// `applyWindowSnapshot`, so there is nothing left to reconcile here.
    private func orderedWindows() -> [ManagedWindow] {
        windowManager.windows
    }

    /// Three-tier grouping used for BOTH the magic-wand sort and the sidebar's
    /// visual row-group dividers: terminals (iTerm2 + Terminal.app) first, then
    /// simulators, then everything else. This is the user's dev-focused order.
    private func windowTier(_ window: ManagedWindow) -> Int {
        if window.isTerminal { return 0 }
        if window.targetKind == "simulator" { return 1 }
        return 2
    }

    private func isWaitingForInput(_ window: ManagedWindow) -> Bool {
        stateDetector.windowStates[window.id] == .waitingForInput
    }

    /// The rotation the wand walks, and where it currently stands.
    private var wandRotation: [WandSortMode] {
        WandSortMode.rotation(fromStored: wandSortModesRaw)
    }

    private var currentWandMode: WandSortMode {
        WandSort.mode(at: wandSortModeIndex, rotation: wandRotation)
    }

    /// Windows this wand acts on, per the configured kinds.
    ///
    /// The old rule was `windowTier($0) <= 1`, which silently meant iTerm2 AND
    /// Terminal.app AND simulators together — there was no way to ask for one
    /// of them.
    private func wandTargets() -> [ManagedWindow] {
        let kinds = WandTargetKinds.fromStored(wandTargetKindsRaw)
        return windowManager.windows.filter { window in
            if window.targetKind == "simulator" { return kinds.contains(.simulator) }
            if window.bundleId == TerminalApp.iterm2.bundleIdentifier { return kinds.contains(.iterm2) }
            if window.bundleId == TerminalApp.terminal.bundleIdentifier { return kinds.contains(.terminalApp) }
            return false
        }
    }

    /// Magic-wand one-tap sort. Snapshots the current arrangement into the
    /// rotation's next order and writes it through `WindowManager.setOrder`
    /// (which the sidebar renders verbatim, so it sticks and stays
    /// drag-tweakable afterward), then switches the configured target kinds on.
    ///
    /// Targets are enabled on EVERY tap and never flipped off. The old
    /// behaviour toggled — tap once to enable everything, tap again to disable
    /// everything — so clicking the wand twice reliably ended with nothing
    /// selected, which read as the button not working. Switching everything off
    /// is still available on Option-click.
    ///
    /// One-shot by design: it does NOT keep re-sorting as states change. Tap
    /// again for the next order in the rotation.
    private func magicSort() {
        let windows = windowManager.windows
        let mode = currentWandMode
        let items = windows.map { window in
            WandSortItem(id: window.id,
                         tier: windowTier(window),
                         subtitle: window.subtitle,
                         isWaitingForInput: isWaitingForInput(window),
                         lastOutputChangeAt: outputActivity.lastOutputChangeAt[window.id])
        }
        let sorted = WandSort.order(items, mode: mode)
        let targets = wandTargets()

        withAnimation(.easeOut(duration: 0.22)) {
            windowManager.setOrder(sorted)
            for target in targets where !target.isEnabled {
                windowManager.toggleWindow(target.id, enabled: true)
            }
        }
        wandSortModeIndex = WandSort.advance(index: wandSortModeIndex, rotation: wandRotation)
    }

    /// Option-click: switch every configured target off. Preserves the one
    /// useful half of the old toggle without making it the thing a second
    /// ordinary click does.
    private func disableAllTargets() {
        withAnimation(.easeOut(duration: 0.22)) {
            for target in wandTargets() where target.isEnabled {
                windowManager.toggleWindow(target.id, enabled: false)
            }
        }
    }

    private func windowList(snapshot: SidebarSnapshot) -> some View {
        List(selection: $selectedWindowId) {
            ForEach(snapshot.rows) { row in
                WindowRow(
                    window: row.window,
                    slot: row.slot,
                    isSelected: selectedWindowId == row.window.id,
                    onToggle: { enabled in
                        windowManager.toggleWindow(row.window.id, enabled: enabled)
                    },
                    onMoveUp: moveAction(for: row.window.id, neighborID: row.previousSameRankID),
                    onMoveDown: moveAction(for: row.window.id, neighborID: row.nextSameRankID)
                )
                .tag(row.window.id)
            }
            .onMove(perform: dragReorder)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    /// Native drag-to-reorder. The rows render in `orderedWindows()` order
    /// (which is `WindowManager.customOrder` verbatim), so a visible-index move
    /// maps directly onto that rendered id list — apply it and write the result
    /// straight back through `setOrder`. Free across tiers on purpose: a
    /// hand-drag is the user explicitly overriding the tier grouping, and
    /// because that order is authoritative the arrangement sticks until the
    /// next magic-wand tap. Complements the per-row chevrons (same-tier nudge)
    /// and the wand (whole-list snap).
    private func dragReorder(from source: IndexSet, to destination: Int) {
        var rendered = orderedWindows().map(\.id)
        rendered.move(fromOffsets: source, toOffset: destination)
        withAnimation(.easeOut(duration: 0.18)) {
            windowManager.setOrder(rendered)
        }
    }

    private func moveAction(for id: String, neighborID: String?) -> (() -> Void)? {
        guard let neighborID else { return nil }
        return { moveWindow(id, beside: neighborID) }
    }

    private func moveWindow(_ id: String, beside neighborID: String) {
        windowManager.swapOrder(id, with: neighborID)
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
            .accessibilityLabel("Refresh window list")
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
                    .accessibilityLabel("Choose a project directory")
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
        // "Remove" means "stop managing it" — the window itself stays on
        // screen and stays in the list. It used to also drop the id from the
        // view's private order list, which only shuffled the row to its tier
        // position; order now lives in WindowManager and rebuilds from the
        // live window set, so there is nothing to prune.
        windowManager.toggleWindow(id, enabled: false)
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
        let appName = newTerminalApp.rawValue
        // The directory comes from an open panel, so it is whatever the user has
        // on disk — spaces, quotes, `$`, backticks. It gets interpolated into a
        // shell `cd` that is itself an AppleScript string literal, so it needs
        // both escapes, shell first. Unquoted, a path with a space simply cd'd
        // to the wrong place; unescaped, a path with a backtick ran a command.
        let cdCommand = "cd \"\(KeystrokeInjector.escapeForShellStatic(newProjectDirectory))\""
        let scriptSafeCommand = KeystrokeInjector.escapeForAppleScriptStatic(cdCommand)
        let script: String

        switch newTerminalApp {
        case .claudeDesktop:
            return
        case .terminal:
            script = """
            tell application "\(appName)"
                activate
                do script "\(scriptSafeCommand)"
            end tell
            """
        case .iterm2:
            script = """
            tell application "\(appName)"
                activate
                tell current window
                    create tab with default profile
                    tell current session
                        write text "\(scriptSafeCommand)"
                    end tell
                end tell
            end tell
            """
        }

        // Await, never block: this is a SwiftUI action on the main actor, and the
        // shared AppleScript queue can be several polls deep (see AppleScriptRunner).
        Task {
            _ = await AppleScriptRunner.runOffMain(script)
            // Refresh after a brief delay to pick up the new window
            try? await Task.sleep(for: .seconds(1))
            windowManager.refreshWindowList()
        }
    }
}

// MARK: - Window Row

private struct WindowRow: View {
    let window: ManagedWindow
    /// Arrange slot, or nil when this window is not part of the layout.
    let slot: Int?
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

            Text(slot.map { "\($0)." } ?? "–")
                .font(.caption.monospacedDigit())
                .foregroundStyle(slot == nil ? .tertiary : .secondary)
                .frame(width: 20, alignment: .trailing)
                .help(slot.map { "Arrange slot \($0)" } ?? "Not included in Arrange — enable it first")

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
                        .accessibilityLabel("Move \(window.name) up")
                    }
                    if let onMoveDown {
                        Button { onMoveDown() } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Move \(window.name) down")
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
