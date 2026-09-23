import SwiftUI

/// Mobile counterpart to VibeCut's desktop Broadcast prompt: review the text,
/// choose open terminal sessions, then enqueue the same prompt to each one.
struct BroadcastPromptSheet: View {
    let windows: [WindowState]
    let prompts: [PromptEntry]
    let isConnected: Bool
    let onSend: (_ text: String, _ targetIDs: [String]) -> Set<String>

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var selectedIDs: Set<String>
    @State private var sendError = ""
    @State private var showSendError = false

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

    init(windows: [WindowState],
         prompts: [PromptEntry],
         isConnected: Bool,
         initialDraft: String,
         onSend: @escaping (_ text: String, _ targetIDs: [String]) -> Set<String>) {
        self.windows = windows
        self.prompts = prompts
        self.isConnected = isConnected
        self.onSend = onSend
        _draft = State(initialValue: initialDraft)
        _selectedIDs = State(initialValue: BroadcastPromptPlan.initialSelection(windows: windows))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Prompt") {
                    TextField("Type a prompt…", text: $draft, axis: .vertical)
                        .lineLimit(4...10)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("broadcast-prompt-field")

                    if !prompts.isEmpty {
                        Menu("Fill from library", systemImage: "text.book.closed") {
                            ForEach(prompts) { prompt in
                                Button(prompt.label) {
                                    draft = prompt.body
                                }
                            }
                        }
                    }
                }

                Section {
                    if eligibleWindows.isEmpty {
                        ContentUnavailableView(
                            "No Open Terminals",
                            systemImage: "terminal",
                            description: Text("Open an iTerm2 or Terminal window on the active Mac, then try again.")
                        )
                    } else {
                        HStack {
                            Button("Select All", action: selectAll)
                            Spacer()
                            Button("Select None", action: selectNone)
                        }

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
                    Text("The prompt is submitted once to each selected terminal on the active Mac. Pending images are not broadcast.")
                }
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
        let text = BroadcastPromptPlan.normalizedText(draft)
        guard canSend else { return }
        let requestedIDs = targetIDs
        let queuedIDs = onSend(text, requestedIDs)
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
