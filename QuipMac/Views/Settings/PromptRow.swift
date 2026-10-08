// PromptRow.swift
// QuipMac — Settings window pane (split out of SettingsView.swift)

import SwiftUI
import Darwin
import AppKit

// MARK: - Prompt Row
//
// Single row in the Prompt Library section. Hover reveals inline pencil +
// trash buttons (so you can edit / delete without first selecting a row).
// Right-click anywhere opens a context menu with Edit / Delete / Reveal in
// Finder. Double-click also edits — three discoverability paths, pick the
// one that fits muscle memory.
struct PromptRow: View {
    let entry: PromptEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    /// The id shown next to the label. Inherited prompts drop the reserved
    /// `vibecut__` filename prefix — the badge already carries the provenance,
    /// so the visible slug matches what VibeCut calls the prompt. The real id
    /// (with prefix) stays untouched for edit/delete/Reveal.
    private var displaySlug: String {
        entry.isInherited && entry.id.hasPrefix(VibeCutPromptMapper.idPrefix)
            ? String(entry.id.dropFirst(VibeCutPromptMapper.idPrefix.count))
            : entry.id
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.label)
                        .font(.system(size: 13, weight: .medium))
                    if entry.isInherited {
                        // Same badge vocabulary as the phone's prompt list; the
                        // pill replaces the raw `vibecut__` prefix in the slug.
                        Text("VibeCut")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .foregroundStyle(Color.purple)
                            .background(.purple.opacity(0.15), in: .capsule)
                            .overlay { Capsule().stroke(Color.purple.opacity(0.4), lineWidth: 0.5) }
                    }
                    if displaySlug != entry.label {
                        Text(displaySlug)
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
                Button("Edit", systemImage: "pencil", action: onEdit)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Edit")

                Button("Delete", systemImage: "trash", action: onDelete)
                    .labelStyle(.iconOnly)
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
