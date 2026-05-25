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
    /// Surface Cursor (`cursor-agent`) in the new-session agent picker. (§7.4)
    static let cursorAgent = "labs.cursorAgent"
    /// Promote in-app numbered prompt chips to prominent, fingerprint-validated
    /// one-tap answer buttons when a window is waiting. (§3.2)
    static let oneTapAnswer = "labs.oneTapAnswer"
    /// Enable export/import of prompt + hot-button "packs" via the Share Sheet. (§6.1)
    static let promptPackSharing = "labs.promptPackSharing"

    /// One row per flag for the Settings → Quip Labs section.
    /// Order here is display order.
    static let all: [(key: String, title: String, summary: String)] = [
        (cursorAgent, "Cursor agent",
         "Add Cursor (cursor-agent) to the new-session agent picker."),
        (oneTapAnswer, "One-tap answers",
         "Big contextual answer buttons when an agent is waiting; the Mac re-checks the prompt before sending."),
        (promptPackSharing, "Prompt & button packs",
         "Share and import prompts and custom buttons as files."),
    ]
}

/// Settings → Quip Labs section. One toggle per `LabsFlags.all` entry.
struct LabsSection: View {
    var body: some View {
        Section {
            ForEach(LabsFlags.all, id: \.key) { feature in
                LabsToggleRow(key: feature.key, title: feature.title, summary: feature.summary)
            }
        } header: {
            Text("Quip Labs")
        } footer: {
            Text("Experimental features, off by default. They may change or break between updates.")
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
