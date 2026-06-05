import Foundation
import SwiftUI

/// Central registry of opt-in "Quip Labs" beta features.
///
/// Each feature is a `UserDefaults`-backed Bool, default **off**, surfaced as a
/// toggle in Settings → Quip Labs. Views gate new surfaces with
/// `@AppStorage(LabsFlags.<key>)`. Keys live here (not as scattered string
/// literals) so the toggle UI and the gate points can never drift apart.
///
/// Apple/iOS-only. All flags default false so an upgrade never silently turns
/// a beta behavior on. (§0)
enum LabsFlags {
    /// Legacy Cursor (`cursor-agent`) flag. Kept so older defaults decode, but
    /// the feature is hidden from Settings while the agent path is paused.
    static let cursorAgent = "labs.cursorAgent"
    /// Promote in-app numbered prompt chips to prominent, fingerprint-validated
    /// one-tap answer buttons when a window is waiting. (§3.2)
    static let oneTapAnswer = "labs.oneTapAnswer"
    /// Enable export/import of prompt + hot-button "packs" via the Share Sheet. (§6.1)
    static let promptPackSharing = "labs.promptPackSharing"

    /// One row per visible flag for the Settings → Quip Labs section.
    /// Order here is display order. Cursor stays out of Settings for now.
    static let visible: [(key: String, title: String, summary: String)] = [
        (oneTapAnswer, "One-tap answers",
         "Big contextual answer buttons when an agent is waiting; the Mac re-checks the prompt before sending."),
        (promptPackSharing, "Prompt & button packs",
         "Share and import prompts and custom buttons as files."),
    ]
}

/// Settings → Quip Labs section. One toggle per `LabsFlags.visible` entry.
struct LabsSection: View {
    var body: some View {
        Section {
            ForEach(LabsFlags.visible, id: \.key) { feature in
                LabsToggleRow(key: feature.key, title: feature.title, summary: feature.summary)
            }
        } header: {
            Text("Beta")
        } footer: {
            Text("Optional experiments. Off by default.")
        }
    }
}

private struct LabsToggleRow: View {
    let title: String
    let summary: String
    @AppStorage private var enabled: Bool

    init(key: String, title: String, summary: String) {
        self.title = title
        self.summary = summary
        self._enabled = AppStorage(wrappedValue: false, key)
    }

    var body: some View {
        Toggle(isOn: $enabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
