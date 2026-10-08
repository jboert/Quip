// PromptsTab.swift
// QuipMac — Settings window pane (split out of SettingsView.swift)

import SwiftUI
import Darwin
import AppKit

// MARK: - Prompts Tab
//
// The prompt library gets its own pane (split out of Projects — prompts are
// text snippets, not project folders). A grouped Form of PromptRows + New /
// Reveal. Editing happens in PromptEditorSheet; writes flow through
// PromptLibrary.put, which triggers the FS-watcher broadcast to every
// connected phone.

struct PromptsTab: View {
    @Environment(PromptLibrary.self) private var library
    @Environment(VibeCutSyncService.self) private var vibeCutSync
    @State private var editingPrompt: PromptEntry?
    @State private var creatingPrompt = false

    private var inheritedCount: Int {
        library.entries.count(where: \.isInherited)
    }

    var body: some View {
        Form {
            vibeCutSection

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
                if inheritedCount > 0 {
                    let title = Text("Prompt Library (\(library.entries.count))")
                    let split = Text("\(library.entries.count - inheritedCount) yours · \(inheritedCount) from VibeCut")
                        .foregroundStyle(.secondary)
                    Text("\(title)  ·  \(split)")
                } else {
                    Text("Prompt Library (\(library.entries.count))")
                }
            } footer: {
                Text("Tapped on the phone, the body is sent verbatim to the active terminal. Edits broadcast to every connected phone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { vibeCutSync.refreshRepoProbe() }
        .sheet(isPresented: $creatingPrompt) {
            PromptEditorSheet(initial: nil) { id, label, body in
                library.put(id: id, label: label, body: body) != nil
            }
        }
        .sheet(item: $editingPrompt) { entry in
            PromptEditorSheet(initial: entry) { id, label, body in
                library.put(id: id, label: label, body: body) != nil
            }
        }
    }

    // MARK: VibeCut sync

    /// Mac-side face of the VibeCut prompt inherit. Everything here reads or
    /// drives plumbing that already existed for the phone's ⟳ button: the repo
    /// probe surfaces `VibeCutPromptReader.defaultRoot()` (and Change… writes
    /// the `vibecutRepoPath` default that was previously `defaults write`-only),
    /// Sync Now runs the same VibeCutSyncService pipeline, and the status line
    /// shows the counts that used to go only to stdout.
    @ViewBuilder
    private var vibeCutSection: some View {
        Section {
            HStack(spacing: 8) {
                switch vibeCutSync.repoFound {
                case .some(true):  StatusDot(kind: .ok, text: "Repo found")
                case .some(false): StatusDot(kind: .bad, text: "Repo not found")
                case .none:        StatusDot(kind: .busy, text: "Checking…")
                }
                Text(vibeCutSync.repoPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("Change…") { changeVibeCutRepo() }
            }

            HStack(spacing: 8) {
                lastSyncLabel
                Spacer()
                if vibeCutSync.isSyncing {
                    ProgressView().controlSize(.small)
                }
                Button("Sync Now") {
                    Task { _ = await vibeCutSync.sync(into: library, trigger: "settings-button") }
                }
                .disabled(vibeCutSync.isSyncing)
            }
        } header: {
            Text("VibeCut")
        } footer: {
            Text("One-way inherit of VibeCut's prompt catalog + packs into the library below. Edits belong in VibeCut; sync here or from the phone (Settings → Prompts → ⟳).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var lastSyncLabel: some View {
        if let outcome = vibeCutSync.lastOutcome {
            if let error = outcome.error {
                Text("Last attempt \(outcome.date.formatted(date: .abbreviated, time: .shortened)) — \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                let packs = outcome.skippedPacks > 0
                    ? " · \(outcome.skippedPacks) pack \(outcome.skippedPacks == 1 ? "file" : "files") unreadable" : ""
                Text("Last sync \(outcome.date.formatted(date: .abbreviated, time: .shortened)) · \(outcome.synced) synced · \(outcome.skipped) skipped\(packs)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Never synced on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func changeVibeCutRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the VibeCut repo root (the folder containing shared/prompts.json)"
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: "vibecutRepoPath")
            vibeCutSync.refreshRepoProbe()
        }
    }
}
