import SwiftUI
import AVFoundation

/// The Prompts hub (Q-42), opened both from the main screen's Prompts button
/// and from Settings → Prompts, so there is one place for everything. A tap
/// fires a `paste_prompt` to the Mac, which pastes the body into the targeted
/// terminal; the visible ↵ button pastes and sends; a long-press offers Edit,
/// Hide and Delete (Delete asks first). Prompts are ranked most-used first
/// for the selected window's agent, hidden ones fold into their own section.
/// Mirrors the Stream Deck "clipboard prompt" pattern without the .scpt
/// round-trip: bodies live on the Mac in
/// ~/Library/Application Support/Quip/prompts/*.txt.
struct PromptLibrarySheet: View {
    var client: WebSocketClient
    /// Closure resolver, NOT a captured value. The prior `var windowId: String?`
    /// shape captured the parent's `selectedWindowId` at NavigationLink
    /// construction time — so if the user changed the active window after
    /// opening Settings, the sheet kept firing prompts at the stale window.
    /// (§B4 wrong-window bug.) Reading via a closure means every paste
    /// fetches the *current* selection at fire time.
    var windowIdProvider: () -> String?
    /// The selected window's agent (a `CLIKind` raw value) for ranking the
    /// generator's examples. Nil ranks on global usage.
    var promptContextProvider: () -> String? = { nil }
    /// The selected window's folder (Q-69): prompts set to other projects
    /// fold into Other Projects. Resolved late, like `windowIdProvider`.
    var projectProvider: () -> String? = { nil }
    /// The windows a prompt can be sent to with Send to… (US-209).
    var windowsProvider: () -> [WindowState] = { [] }
    /// Set when the hub is opened from the main screen: firing goes through
    /// the caller (which records usage and closes the sheet). Nil in
    /// Settings, where the sheet fires directly and stays open.
    var onPick: ((PromptEntry, _ pressReturn: Bool) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Keeps the search index between keystrokes (US-102).
    @State private var searchCache = PromptSearchCache()
    @State private var confirmingDelete: PromptEntry?
    @State private var showHiddenPrompts = false
    @State private var showOtherProjects = false
    @State private var showOtherAgents = false
    @State private var lastFiredId: String?
    /// What the row under `lastFiredId` says: "Pasted ✓" or "Sent to api ✓".
    @State private var lastFiredNote = "Pasted ✓"
    /// The prompt whose Send to… window list is open.
    @State private var sendingTo: PromptEntry?
    @State private var editing: PromptEntry?
    @State private var creatingNew: Bool = false
    @State private var showingGenerator: Bool = false
    @State private var pendingGeneratedDraft: PromptEntry?
    @State private var generatedDraft: PromptEntry?
    @AppStorage(LabsFlags.promptPackSharing) private var labsPromptPacks = false
    @State private var shareItem: PackShareItem?
    @State private var exportError: String?
    @State private var latestPutAck: PutPromptAckMessage?
    @State private var pendingDeleteIDs: Set<String> = []
    @State private var deleteTimeouts: [UUID: Task<Void, Never>] = [:]
    @State private var deleteErrorMessage: String?
    // VibeCut inherit (US-004/005): manual sync state + per-prompt hide set.
    @AppStorage("hiddenPromptIDsJSON") private var hiddenPromptIDsJSON: String = "[]"
    // Read-only here: the generator ranks its examples from them (Q-35).
    @AppStorage("promptUsageJSON") private var promptUsageJSON: String = "{}"
    @AppStorage("promptUsageMRUJSON") private var promptUsageMRUJSON: String = "{}"
    @State private var syncing = false
    @State private var syncResult: String?
    @State private var syncTimeout: Task<Void, Never>?
    @State private var syncResultClear: Task<Void, Never>?

    var body: some View {
        List {
            if client.promptLibrary.isEmpty {
                Section {
                    Text("No prompts yet. Tap + above to create one, or drop .txt files into ~/Library/Application Support/Quip/prompts/ on the Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Library")
                }
            } else {
                let hub = hubSections
                if hub.visible.isEmpty && hub.hidden.isEmpty && hub.otherProjects.isEmpty && hub.otherAgents.isEmpty {
                    Section {
                        Text("No matches for \"\(query)\"")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                if !hub.visible.isEmpty {
                    Section {
                        ForEach(hub.visible) { entry in hubRow(entry, note: hub.notes[entry.id]) }
                    } header: {
                        HStack {
                            Text(query.isEmpty ? "Most used first" : "Best match first")
                            Spacer()
                            if let syncResult {
                                Text(syncResult)
                                    .font(.caption)
                                    .foregroundStyle(syncResult.contains("synced") ? .green : .orange)
                            }
                            Text(query.isEmpty
                                 ? "\(client.promptLibrary.count)"
                                 : "\(hub.visible.count + hub.hidden.count) of \(client.promptLibrary.count)")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    } footer: {
                        Text("Tap to paste. ↵ pastes and sends. Hold a prompt for more. Swipe right to send it somewhere, left to edit, hide or delete it. A prompt set to a project or an agent shows only in that project's or agent's windows. {{folder}}, {{agent}}, {{clipboard}}… fill in on the Mac.")
                    }
                }
                if !hub.otherProjects.isEmpty {
                    Section {
                        if showOtherProjects || !query.isEmpty {
                            ForEach(hub.otherProjects) { entry in hubRow(entry, note: hub.notes[entry.id]) }
                        }
                    } header: {
                        Button {
                            showOtherProjects.toggle()
                        } label: {
                            Label("Other Projects (\(hub.otherProjects.count))",
                                  systemImage: showOtherProjects || !query.isEmpty ? "chevron.down" : "chevron.right")
                        }
                        .font(.caption)
                    }
                }
                if !hub.otherAgents.isEmpty {
                    Section {
                        if showOtherAgents || !query.isEmpty {
                            ForEach(hub.otherAgents) { entry in hubRow(entry, note: hub.notes[entry.id]) }
                        }
                    } header: {
                        Button {
                            showOtherAgents.toggle()
                        } label: {
                            Label("Other Agents (\(hub.otherAgents.count))",
                                  systemImage: showOtherAgents || !query.isEmpty ? "chevron.down" : "chevron.right")
                        }
                        .font(.caption)
                    }
                }
                if !hub.hidden.isEmpty {
                    Section {
                        if showHiddenPrompts || !query.isEmpty {
                            ForEach(hub.hidden) { entry in hubRow(entry, note: hub.notes[entry.id]) }
                        }
                    } header: {
                        Button {
                            showHiddenPrompts.toggle()
                        } label: {
                            Label("Hidden (\(hub.hidden.count))",
                                  systemImage: showHiddenPrompts || !query.isEmpty ? "chevron.down" : "chevron.right")
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        // Prompt ids are lower-case ("ship-it"); a capitalized or autocorrected
        // query would show "Ship-it" and still match, which reads as a bug.
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
        .confirmationDialog(
            "Delete \"\(confirmingDelete?.label ?? "")\"?",
            isPresented: Binding(get: { confirmingDelete != nil },
                                 set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = confirmingDelete { deletePrompt(entry) }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text("This removes it from the Mac too.")
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Prompts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if onPick != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            // Less-used actions, named instead of three bare icons.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingGenerator = true
                    } label: {
                        Label("Prompt generator…", systemImage: "wand.and.stars")
                    }
                    Button {
                        syncFromVibeCut()
                    } label: {
                        Label("Sync from VibeCut", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(syncing || !(client.isConnected && client.isAuthenticated))
                    // §6.1 — export the whole library as a shareable .quippack (Labs).
                    if labsPromptPacks && !client.promptLibrary.isEmpty {
                        Button {
                            let pack = SharedPromptPack(name: "Quip Prompts",
                                                        prompts: client.promptLibrary, buttons: [])
                            do {
                                shareItem = PackShareItem(url: try pack.writeToTemp(filename: "quip-prompts"))
                            } catch {
                                // Same dead-button failure as the buttons export.
                                print("[Quip][Packs] export prompts FAILED err=\(error)")
                                exportError = "Couldn't stage the prompt pack for sharing. \(error.localizedDescription)"
                            }
                        } label: {
                            Label("Share prompts", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    if syncing {
                        ProgressView()
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .accessibilityLabel("More prompt actions")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    creatingNew = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New prompt")
            }
        }
        .sheet(isPresented: $creatingNew) {
            PromptEditorSheet(initial: nil, existingIDs: existingPromptIDs, currentProject: projectProvider(),
                              latestAck: latestPutAck) { entry, messageId in
                putPrompt(entry, messageId: messageId)
            }
        }
        .sheet(isPresented: $showingGenerator, onDismiss: {
            if let draft = pendingGeneratedDraft {
                pendingGeneratedDraft = nil
                generatedDraft = draft
            }
        }) {
            PromptGeneratorSheet(
                existingIDs: Set(client.promptLibrary.map(\.id)),
                context: promptContextProvider(),
                examples: generatorExamples()
            ) { draft in
                pendingGeneratedDraft = draft
                showingGenerator = false
            }
        }
        .sheet(item: $generatedDraft) { draft in
            PromptEditorSheet(initial: nil, draft: draft, existingIDs: existingPromptIDs,
                              currentProject: projectProvider(), latestAck: latestPutAck) { entry, messageId in
                putPrompt(entry, messageId: messageId)
            }
        }
        .sheet(item: $sendingTo) { entry in
            SendToWindowSheet(title: entry.label, action: .prompt(id: entry.id, pressReturn: false),
                              targets: SendToTargets.targets(from: windowsProvider(), selectedID: windowIdProvider())) { windowID, action in
                if case .prompt(_, let pressReturn) = action { send(entry, to: windowID, pressReturn: pressReturn) }
            }
        }
        .sheet(item: $editing) { entry in
            PromptEditorSheet(initial: entry, currentProject: projectProvider(), latestAck: latestPutAck) { entry, messageId in
                putPrompt(entry, messageId: messageId)
            }
        }
        .sheet(item: $shareItem) { item in
            DiagnosticsShareSheet(items: [item.url])
        }
        .alert("Delete failed", isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { deleteErrorMessage = nil }
        } message: {
            Text(deleteErrorMessage ?? "The prompt could not be deleted.")
        }
        .alert("Couldn't share prompts", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .onAppear {
            client.onPutPromptAck = { ack in
                latestPutAck = ack
            }
            client.onDeletePromptAck = { ack in
                handleDeleteAck(ack)
            }
            client.onSyncVibeCutAck = { ack in
                handleSyncAck(ack)
            }
        }
        .onDisappear {
            deleteTimeouts.values.forEach { $0.cancel() }
            deleteTimeouts.removeAll()
            syncTimeout?.cancel()
            syncResultClear?.cancel()
            client.onPutPromptAck = nil
            client.onDeletePromptAck = nil
            client.onSyncVibeCutAck = nil
        }
    }

    /// Ask the Mac to re-read VibeCut's catalog and re-land the inherited set. The
    /// refreshed prompts arrive via the normal `prompt_library` broadcast; this ack
    /// just reports the count. 8s watchdog covers a lost ack.
    /// The visible prompts the user fires most in the selected window's
    /// agent, for the generator to start from (Q-35).
    private func generatorExamples() -> [PromptEntry] {
        PromptGenerator.topExamples(
            PromptHideState.visible(client.promptLibrary, hiddenJSON: hiddenPromptIDsJSON),
            store: PromptRanker.load(usageJSON: promptUsageJSON, legacyMRUJSON: promptUsageMRUJSON),
            context: promptContextProvider(),
            at: Date()
        )
    }

    private func syncFromVibeCut() {
        guard client.isConnected && client.isAuthenticated else { return }
        syncing = true
        syncResult = nil
        syncResultClear?.cancel()
        let messageId = UUID()
        guard client.send(SyncVibeCutMessage(messageId: messageId)) else {
            syncing = false
            showSyncResult("Sync failed to send")
            return
        }
        syncTimeout?.cancel()
        syncTimeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard syncing else { return }
            syncing = false
            showSyncResult("Sync timed out")
        }
    }

    private func handleSyncAck(_ ack: SyncVibeCutAckMessage) {
        syncTimeout?.cancel()
        syncing = false
        if let error = ack.error {
            showSyncResult(error)
        } else if let badPacks = ack.skippedPacks, badPacks > 0 {
            showSyncResult("\(ack.syncedCount) synced · \(badPacks) pack file\(badPacks == 1 ? "" : "s") skipped")
        } else {
            showSyncResult("\(ack.syncedCount) synced")
        }
    }

    private func showSyncResult(_ text: String) {
        syncResult = text
        syncResultClear?.cancel()
        syncResultClear = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            syncResult = nil
        }
    }

    /// `note` says why a search matched (US-102): the body text around a
    /// match that is not in the name replaces the usual first line, and a
    /// match that needed a typo says so.
    @ViewBuilder
    private func promptRow(_ entry: PromptEntry, note: PromptHub.MatchNote? = nil) -> some View {
        let hidden = PromptHideState.isHidden(entry.id, in: hiddenPromptIDsJSON)
        let preview = note?.excerpt ?? entry.bodyPreview
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.label)
                    .font(.system(size: 14, weight: .medium))
                if entry.isInherited { promptBadge("VibeCut") }
                if hidden { promptBadge("Hidden") }
                let projects = PromptProjects.projects(of: entry)
                if let first = projects.first {
                    promptBadge(projects.count > 1 ? "\(first) +\(projects.count - 1)" : first)
                }
                Spacer()
                Text("\(entry.bodyBytes)B")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Text(preview)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let closeMatch = note?.closeMatch {
                Text(closeMatch)
                    .font(.system(size: 10))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
            // Q-34c — what the Mac will fill in at paste.
            // Absent (no extra height) when there is nothing.
            if let hint = PromptVariables.hint(for: entry.body) {
                Label(hint, systemImage: "curlybraces")
                    .font(.system(size: 10))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
            if lastFiredId == entry.id {
                Text(lastFiredNote)
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
            }
            if pendingDeleteIDs.contains(entry.id) {
                Label("Deleting...", systemImage: "hourglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(hidden ? 0.4 : 1)
        .contentShape(Rectangle())
        .onTapGesture { fire(entry, pressReturn: false) }
        // Send stays a visible button (`hubRow`); a long-press here is the
        // context menu, so it cannot also mean "send".
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(entry.label)
        .accessibilityValue([hidden ? "Hidden" : preview, note?.closeMatch, PromptVariables.hint(for: entry.body)]
            .compactMap { $0 }
            .joined(separator: ". "))
        .accessibilityHint("Pastes this prompt into the active terminal")
        .accessibilityAction(named: "Paste and send") { fire(entry, pressReturn: true) }
    }

    /// One hub row: the prompt (tap pastes), a visible ↵ that pastes and
    /// sends, every prompt action on long-press, and one swipe rule (US-209):
    /// right to send, left to manage (`PromptRowActions`).
    @ViewBuilder
    private func hubRow(_ entry: PromptEntry, note: PromptHub.MatchNote? = nil) -> some View {
        let hidden = PromptHideState.isHidden(entry.id, in: hiddenPromptIDsJSON)
        HStack(spacing: 10) {
            promptRow(entry, note: note)
            Button {
                fire(entry, pressReturn: true)
            } label: {
                Image(systemName: "return")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Paste and send \(entry.label)")
        }
        .contextMenu {
            ForEach(PromptRowActions.menu(hidden: hidden), id: \.title) { action in
                rowActionButton(action, entry)
            }
        }
        .swipeActions(edge: .leading) {
            ForEach(PromptRowActions.leadingSwipe, id: \.title) { action in
                rowActionButton(action, entry)
            }
        }
        .swipeActions(edge: .trailing) {
            ForEach(PromptRowActions.trailingSwipe(hidden: hidden), id: \.title) { action in
                rowActionButton(action, entry)
            }
        }
    }

    private func rowActionButton(_ action: PromptRowAction, _ entry: PromptEntry) -> some View {
        Button(role: action == .delete ? .destructive : nil) {
            perform(action, on: entry)
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
        .tint(rowActionTint(action))
        .disabled(rowActionDisabled(action, entry))
    }

    private func perform(_ action: PromptRowAction, on entry: PromptEntry) {
        switch action {
        case .paste: fire(entry, pressReturn: false)
        case .pasteAndSend: fire(entry, pressReturn: true)
        case .sendTo: sendingTo = entry
        case .broadcast: broadcast(entry)
        case .edit: editing = entry
        case .hide, .show: hiddenPromptIDsJSON = PromptHideState.toggled(entry.id, in: hiddenPromptIDsJSON)
        case .delete: confirmingDelete = entry
        }
    }

    private func rowActionTint(_ action: PromptRowAction) -> Color? {
        switch action {
        case .sendTo, .broadcast: return .indigo
        case .pasteAndSend, .paste: return .green
        case .edit: return .blue
        case .hide, .show: return .gray
        case .delete: return nil
        }
    }

    private func rowActionDisabled(_ action: PromptRowAction, _ entry: PromptEntry) -> Bool {
        switch action {
        case .sendTo, .broadcast: return !client.isConnected
        case .delete: return pendingDeleteIDs.contains(entry.id)
        default: return false
        }
    }

    /// US-209: paste into a window other than the selected one, which stays
    /// selected; the hub stays open and the row says where it went.
    private func send(_ entry: PromptEntry, to windowID: String, pressReturn: Bool) {
        guard client.send(PastePromptMessage(id: entry.id, windowId: windowID, pressReturn: pressReturn)) else { return }
        let window = windowsProvider().first { $0.id == windowID }
        promptUsageJSON = PromptRanker.encode(PromptRanker.recording(
            entry.id, context: window.map { ($0.cliKind ?? .shell).rawValue }, at: Date(),
            in: PromptRanker.load(usageJSON: promptUsageJSON, legacyMRUJSON: promptUsageMRUJSON)))
        if promptUsageMRUJSON != "{}" { promptUsageMRUJSON = "{}" }
        lastFiredNote = "Sent to \(window?.displayTitle ?? "window") ✓"
        lastFiredId = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if lastFiredId == entry.id { lastFiredId = nil }
        }
    }

    /// US-108 — open the main screen's Broadcast sheet with this prompt. This
    /// hub can sit inside Settings, so it closes and the main screen opens
    /// the sheet once nothing is in the way.
    private func broadcast(_ entry: PromptEntry) {
        // Posted before `dismiss()`: the main screen decides whether to wait
        // for a sheet to animate away by reading its own flags, and
        // `dismiss()` flips the main-screen hub's flag synchronously, which
        // would make the Broadcast sheet present into a dismissal in
        // progress and never appear.
        NotificationCenter.default.post(name: .quipOpenBroadcast,
                                        object: BroadcastLink.Request(text: nil, promptID: entry.id))
        dismiss()
    }

    private var hubSections: PromptHub.Sections {
        PromptHub.sections(
            client.promptLibrary,
            hiddenJSON: hiddenPromptIDsJSON,
            store: PromptRanker.load(usageJSON: promptUsageJSON, legacyMRUJSON: promptUsageMRUJSON),
            context: promptContextProvider(),
            query: query,
            at: Date(),
            cache: searchCache,
            projectFilter: .project(projectProvider())
        )
    }

    /// Compact provenance / state capsule, quieter than the label so the merged
    /// list still scans as one library.
    @ViewBuilder
    private func promptBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }

    private func fire(_ entry: PromptEntry, pressReturn: Bool) {
        if let onPick {
            onPick(entry, pressReturn)
            return
        }
        guard let wid = windowIdProvider(), !wid.isEmpty else { return }
        if client.send(PastePromptMessage(id: entry.id, windowId: wid, pressReturn: pressReturn)) {
            // US-112 — a fire from Settings → Prompts counts like one from the
            // main screen.
            promptUsageJSON = PromptRanker.encode(PromptRanker.recording(
                entry.id, context: promptContextProvider(), at: Date(),
                in: PromptRanker.load(usageJSON: promptUsageJSON, legacyMRUJSON: promptUsageMRUJSON)))
            if promptUsageMRUJSON != "{}" { promptUsageMRUJSON = "{}" }
        }
        lastFiredNote = "Pasted ✓"
        lastFiredId = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if lastFiredId == entry.id { lastFiredId = nil }
        }
    }

    /// Ids the Mac already holds, for the editor's collision warning.
    private var existingPromptIDs: Set<String> {
        Set(client.promptLibrary.map(\.id))
    }

    private func putPrompt(_ entry: PromptEntry, messageId: UUID) -> Bool {
        guard client.isConnected && client.isAuthenticated else { return false }
        return client.send(PutPromptMessage(
            id: entry.id,
            label: entry.label,
            body: entry.body,
            messageId: messageId,
            tags: entry.tags,
            targetAgent: entry.targetAgent,
            description: entry.description
        ))
    }

    private func deletePrompt(_ entry: PromptEntry) {
        guard client.isConnected && client.isAuthenticated else {
            deleteErrorMessage = "Connect to the Mac before deleting prompts."
            return
        }
        let messageId = UUID()
        pendingDeleteIDs.insert(entry.id)
        guard client.send(DeletePromptMessage(id: entry.id, messageId: messageId)) else {
            pendingDeleteIDs.remove(entry.id)
            deleteErrorMessage = "Could not send the delete request to the Mac."
            return
        }
        deleteTimeouts[messageId]?.cancel()
        deleteTimeouts[messageId] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard pendingDeleteIDs.contains(entry.id) else { return }
            pendingDeleteIDs.remove(entry.id)
            deleteTimeouts.removeValue(forKey: messageId)
            deleteErrorMessage = "Timed out waiting for the Mac to confirm delete."
        }
    }

    private func handleDeleteAck(_ ack: DeletePromptAckMessage) {
        deleteTimeouts[ack.messageId]?.cancel()
        deleteTimeouts.removeValue(forKey: ack.messageId)
        pendingDeleteIDs.remove(ack.id)
        if !ack.success {
            deleteErrorMessage = ack.error ?? "The Mac could not delete this prompt."
        }
    }
}
