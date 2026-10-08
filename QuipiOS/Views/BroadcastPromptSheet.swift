import SwiftUI

/// What the Broadcast sheet opens with: the draft, the library prompt it came
/// from (US-107), and which terminals start selected. `selection` nil selects
/// every terminal; a retry (US-111) passes only the ones that did not confirm.
struct BroadcastSheetRequest: Identifiable {
    let id = UUID()
    var draft: String
    var source: BroadcastSource?
    var selection: Set<String>?
}

/// One tap on Send, as the sheet hands it to the main screen.
struct BroadcastSend {
    /// The draft as sent, kept so a retry can reopen the sheet with it.
    let text: String
    let source: BroadcastSource?
    let route: BroadcastRoute
    let targetIDs: [String]
    let pressReturn: Bool
}

extension Notification.Name {
    /// Opens the Broadcast sheet on the main screen. `object` is a
    /// `BroadcastLink.Request`: posted by the Prompts hub's "Broadcast…"
    /// action (US-108), which can sit inside Settings, and by the
    /// `quip://broadcast` link (US-114).
    static let quipOpenBroadcast = Notification.Name("quip.openBroadcast")
}

struct BroadcastPromptSheet: View {
    let windows: [WindowState]
    let library: [PromptEntry]
    let isConnected: Bool
    let onSend: (BroadcastSend) -> Set<String>

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    /// The library prompt the draft came from. Kept while the user edits:
    /// `BroadcastRoute` pastes the prompt only while the text still matches it.
    @State private var source: BroadcastSource?
    @State private var selectedIDs: Set<String>
    @State private var sendError = ""
    @State private var showSendError = false
    @State private var searchCache = PromptSearchCache()
    /// US-110 — off pastes into every terminal and leaves Return to the user.
    /// This phone only; it is not in the Mac preferences backup.
    @AppStorage("broadcastPressReturn") private var pressReturn = true
    @AppStorage("hiddenPromptIDsJSON") private var hiddenPromptIDsJSON = "[]"
    @AppStorage("promptUsageJSON") private var promptUsageJSON = "{}"
    @AppStorage("promptUsageMRUJSON") private var promptUsageMRUJSON = "{}"

    private var eligibleWindows: [WindowState] {
        BroadcastPromptPlan.eligibleWindows(windows)
    }

    private var targetIDs: [String] {
        BroadcastPromptPlan.targetIDs(windows: windows, selectedIDs: selectedIDs)
    }

    private var canSend: Bool {
        BroadcastPromptPlan.canSend(
            text: draft,
            windows: windows,
            selectedIDs: selectedIDs,
            isConnected: isConnected
        )
    }

    private var usageStore: PromptRanker.Store {
        PromptRanker.load(usageJSON: promptUsageJSON, legacyMRUJSON: promptUsageMRUJSON)
    }

    /// Several targets, so no single agent context ranks the library.
    private var suggestions: BroadcastSuggestions.Result {
        BroadcastSuggestions.suggestions(
            draft: draft, library: library, hiddenJSON: hiddenPromptIDsJSON,
            store: usageStore, context: nil, at: Date(),
            chosenBody: source?.body, cache: searchCache
        )
    }

    /// Everything the "All prompts…" menu lists: visible prompts, most used first.
    private var allPrompts: [PromptEntry] {
        PromptHub.sections(library, hiddenJSON: hiddenPromptIDsJSON, store: usageStore,
                           context: nil, query: "", at: Date()).visible
    }

    private var isPastingPrompt: Bool {
        if case .pastePrompt = BroadcastRoute.route(text: draft, source: source) { return true }
        return false
    }

    init(windows: [WindowState],
         library: [PromptEntry],
         isConnected: Bool,
         request: BroadcastSheetRequest,
         onSend: @escaping (BroadcastSend) -> Set<String>) {
        self.windows = windows
        self.library = library
        self.isConnected = isConnected
        self.onSend = onSend
        _draft = State(initialValue: request.draft)
        _source = State(initialValue: request.source)
        let all = BroadcastPromptPlan.initialSelection(windows: windows)
        _selectedIDs = State(initialValue: request.selection.map { $0.intersection(all) } ?? all)
    }

    var body: some View {
        NavigationStack {
            Form {
                promptSection
                suggestionsSection
                terminalsSection
            }
            .navigationTitle("Broadcast Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send to \(targetIDs.count)", action: send)
                        .disabled(!canSend)
                }
            }
            .alert("Broadcast not fully queued", isPresented: $showSendError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(sendError)
            }
            .onChange(of: windows) { _, newWindows in
                selectedIDs = BroadcastPromptPlan.reconciledSelection(
                    selectedIDs,
                    windows: newWindows
                )
            }
        }
    }

    private var promptSection: some View {
        Section("Prompt") {
            TextField("Type a prompt…", text: $draft, axis: .vertical)
                .lineLimit(4...10)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("broadcast-prompt-field")

            // US-107 — typed or edited text goes out as written.
            if let hint = BroadcastRoute.placeholderHint(text: draft, source: source) {
                Label(hint, systemImage: "curlybraces")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            if !allPrompts.isEmpty {
                Menu("All prompts…", systemImage: "text.book.closed") {
                    ForEach(allPrompts) { prompt in
                        Button(prompt.label) { choose(prompt) }
                    }
                }
            }

            Toggle(isOn: $pressReturn) {
                Label("Press Return", systemImage: "return")
            }
        }
    }

    /// US-106 — the Most used shelf for an empty field, suggestions once it
    /// holds 2 or more characters. A tap only fills the field.
    @ViewBuilder
    private var suggestionsSection: some View {
        let result = suggestions
        if result.kind != .none, !result.prompts.isEmpty {
            Section(result.kind == .mostUsed ? "Most used" : "Suggestions") {
                ForEach(result.prompts) { prompt in
                    Button {
                        choose(prompt)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(prompt.label)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(prompt.bodyPreview)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Fills the prompt field. Nothing is sent until you tap Send.")
                }
            }
        }
    }

    private var terminalsSection: some View {
        Section {
            if eligibleWindows.isEmpty {
                ContentUnavailableView(
                    isConnected ? "No Open Terminals" : "Not Connected",
                    systemImage: "terminal",
                    description: Text(isConnected
                                      ? "Open an iTerm2 or Terminal window on the active Mac, then try again."
                                      : "Connect to a Mac to choose terminals. Nothing is sent until you tap Send.")
                )
            } else {
                HStack {
                    Button("Select All", action: selectAll)
                    Spacer()
                    Button("Select None", action: selectNone)
                }
                // Two buttons in one Form row: without a borderless style a
                // tap anywhere in the row fires BOTH, All then None, so Select
                // All could never take (found in the simulator pass).
                .buttonStyle(.borderless)

                ForEach(eligibleWindows) { window in
                    Button {
                        toggle(window.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedIDs.contains(window.id)
                                  ? "checkmark.circle.fill"
                                  : "circle")
                                .foregroundStyle(selectedIDs.contains(window.id)
                                                 ? Color.accentColor
                                                 : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(primaryTitle(for: window))
                                    .foregroundStyle(.primary)
                                Text(window.app)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(primaryTitle(for: window)), \(window.app)")
                    .accessibilityValue(selectedIDs.contains(window.id) ? "Selected" : "Not selected")
                }
            }
        } header: {
            Text("Terminals")
        } footer: {
            Text(footerText)
        }
    }

    private var footerText: String {
        let delivery = pressReturn
            ? "The prompt is submitted once to each selected terminal on the active Mac."
            : "The prompt is pasted into each selected terminal without pressing Return."
        let filling = isPastingPrompt ? " Each terminal gets its own {{folder}}, {{agent}} and other values." : ""
        return delivery + filling + " Pending images are not broadcast."
    }

    private func choose(_ prompt: PromptEntry) {
        draft = prompt.body
        source = BroadcastSource(promptID: prompt.id, body: prompt.body)
    }

    private func selectAll() {
        selectedIDs = BroadcastPromptPlan.initialSelection(windows: windows)
    }

    private func selectNone() {
        selectedIDs.removeAll()
    }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func primaryTitle(for window: WindowState) -> String {
        guard let folder = window.folder, !folder.isEmpty else { return window.name }
        return folder
    }

    private func send() {
        guard canSend else { return }
        let requestedIDs = targetIDs
        let queuedIDs = onSend(BroadcastSend(
            text: BroadcastPromptPlan.normalizedText(draft),
            source: source,
            route: BroadcastRoute.route(text: draft, source: source),
            targetIDs: requestedIDs,
            pressReturn: pressReturn
        ))
        let failedIDs = BroadcastPromptPlan.failedSelection(
            requestedIDs: requestedIDs,
            queuedIDs: queuedIDs
        )
        guard failedIDs.isEmpty else {
            selectedIDs = failedIDs
            let count = failedIDs.count
            sendError = "Quip could not queue the prompt for \(count) terminal\(count == 1 ? "" : "s"). Only those terminals remain selected for retry."
            showSendError = true
            return
        }
        dismiss()
    }
}
