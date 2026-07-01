import SwiftUI

/// Identifiable wrapper for a decoded incoming pack awaiting import confirmation. (§6.1)
struct ImportablePack: Identifiable {
    let id = UUID()
    let pack: SharedPromptPack
}

/// Identifiable wrapper for a `quip://share` draft awaiting review before send.
/// Parked by the deep-link handler and rendered by the pending-share UI (US-004).
struct PendingContentShare: Identifiable {
    let id = UUID()
    let draft: ContentShareDraft
    /// Requested mode from the link's `mode` param; defaults to `.summarize`
    /// when the producer didn't specify one.
    var mode: ContentSharePromptMode

    init(draft: ContentShareDraft, mode: ContentSharePromptMode?) {
        self.draft = draft
        self.mode = mode ?? .summarize
    }
}

/// Import preview — lists what a `.quippack` contains and requires explicit
/// confirmation (never silent). (§6.1)
struct ImportPackSheet: View {
    let pack: SharedPromptPack
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !pack.prompts.isEmpty {
                    Section("Prompts (\(pack.prompts.count))") {
                        ForEach(pack.prompts) { p in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.label).font(.system(size: 14, weight: .medium))
                                Text(p.bodyPreview)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                if !pack.buttons.isEmpty {
                    Section("Buttons (\(pack.buttons.count))") {
                        ForEach(pack.buttons) { b in
                            Text(b.label).font(.system(size: 14))
                        }
                    }
                }
            }
            .navigationTitle(pack.name ?? "Import Pack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import") { onConfirm(); dismiss() }.bold()
                }
            }
        }
    }
}
