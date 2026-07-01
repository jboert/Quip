import SwiftUI

/// Review-before-send UI for a parked `quip://share` draft (US-004).
///
/// Renders the shared `ContentShareReviewState`: the reviewer picks a prompt
/// mode and a target window, sees the resolved source attribution + final URL,
/// and only then can Send. Nothing is sent until they confirm — Cancel dismisses
/// without touching the selected window or emitting any message. The actual send
/// path is wired by the parent via `onSend` (US-005).
struct ContentShareReviewSheet: View {
    let pending: PendingContentShare
    let windows: [WindowState]
    let isConnected: Bool
    /// Called with the chosen target window id + mode when Send is tapped.
    var onSend: (_ windowId: String, _ mode: ContentSharePromptMode) -> Void
    var onCancel: () -> Void

    @State private var mode: ContentSharePromptMode
    @State private var selectedWindowId: String?

    init(
        pending: PendingContentShare,
        windows: [WindowState],
        isConnected: Bool,
        initialWindowId: String?,
        onSend: @escaping (_ windowId: String, _ mode: ContentSharePromptMode) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.pending = pending
        self.windows = windows
        self.isConnected = isConnected
        self.onSend = onSend
        self.onCancel = onCancel
        _mode = State(initialValue: pending.mode)
        // Seed the target with whatever window is already selected in the app,
        // so a user who shares while a window is focused can Send immediately.
        _selectedWindowId = State(initialValue: initialWindowId)
    }

    private var selectedWindowName: String? {
        guard let id = selectedWindowId else { return nil }
        return windows.first(where: { $0.id == id })?.name
    }

    private var state: ContentShareReviewState {
        ContentShareReviewState(
            draft: pending.draft,
            mode: mode,
            selectedWindowId: selectedWindowId,
            selectedWindowName: selectedWindowName,
            isConnected: isConnected
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(state.title)
                        .font(.system(size: 16, weight: .semibold))
                    if let label = state.sourceLabel {
                        Text(label)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if let summary = state.summary {
                        Text(summary)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    if let url = state.finalSourceURL {
                        Text(url)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Section("Mode") {
                    Picker("Mode", selection: $mode) {
                        ForEach(ContentShareReviewState.availableModes, id: \.self) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Send to") {
                    if windows.isEmpty {
                        Text("No windows available")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Window", selection: $selectedWindowId) {
                            Text("None").tag(String?.none)
                            ForEach(windows) { w in
                                Text(w.name).tag(String?.some(w.id))
                            }
                        }
                    }
                    if !isConnected {
                        Text("Not connected")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Review Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Send") {
                        if let id = selectedWindowId { onSend(id, mode) }
                    }
                    .bold()
                    .disabled(!state.canSend)
                }
            }
        }
    }
}
