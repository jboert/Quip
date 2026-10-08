// PromptEditorSheet.swift
// QuipMac — Settings window pane (split out of SettingsView.swift)

import SwiftUI
import Darwin
import AppKit

// MARK: - Prompt Editor Sheet (Mac)
//
// Form-style editor matching the iOS PromptEditorSheet. `initial=nil`
// = new prompt (id editable); non-nil = edit (id locked because the
// id IS the filename — renaming would orphan keystroke bindings on
// the phone). Save fires `onSave(id, label, body)`; caller writes
// through PromptLibrary.put which triggers the FS-watcher broadcast.

struct PromptEditorSheet: View {
    let initial: PromptEntry?
    let onSave: (_ id: String, _ label: String, _ body: String) -> Bool
    @Environment(\.dismiss) private var dismiss

    @State private var idText: String = ""
    @State private var labelText: String = ""
    @State private var bodyText: String = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(initial == nil ? "New prompt" : "Edit prompt")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Id (filename)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. ship-it", text: $idText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(initial != nil)
                Text(initial == nil
                     ? "Allowed: letters, digits, dash, underscore, dot. Spaces become dashes."
                     : "Id can't be changed after creation — would orphan phone-side bindings. Delete and recreate to rename.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Label (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Display label — defaults to id if empty", text: $labelText)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Body")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(bodyText.utf8.count) B")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                TextEditor(text: $bodyText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 200)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    }
                Text("Sent verbatim to the active terminal when the row is tapped on the phone. No template expansion.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Save failed: \(saveError)")
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            if let initial {
                idText = initial.id
                labelText = initial.label == initial.id ? "" : initial.label
                bodyText = initial.body
            }
        }
    }

    private var canSave: Bool {
        !idText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let id = idText.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = labelText.trimmingCharacters(in: .whitespaces)
        let body = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !body.isEmpty else { return }
        saveError = nil
        guard onSave(id, label.isEmpty ? id : label, body) else {
            saveError = "Quip couldn't save this prompt. Check that the prompts folder is writable, then try again."
            return
        }
        dismiss()
    }
}
