import SwiftUI
import AVFoundation

/// Create / edit form for a single prompt. `initial=nil` = new-prompt
/// flow (id field editable); non-nil = edit existing (id locked, only
/// label/body mutable). Save fires the caller's onSave with the final entry
/// and a correlation id. The sheet stays open until the Mac acks the disk
/// write, so a queued WebSocket send is not mistaken for a saved prompt.
struct PromptEditorSheet: View {
    let initial: PromptEntry?
    var draft: PromptEntry? = nil
    /// Ids already in the library, so the new-prompt flow can warn before a
    /// save silently replaces a neighbour. Empty is safe — it just disables
    /// the collision warning.
    var existingIDs: Set<String> = []
    /// The selected window's folder, offered as "Only show in …" (Q-69).
    var currentProject: String? = nil
    let latestAck: PutPromptAckMessage?
    let onSave: (_ entry: PromptEntry, _ messageId: UUID) -> Bool
    @Environment(\.dismiss) private var dismiss

    @State private var idText: String = ""
    @State private var labelText: String = ""
    @State private var bodyText: String = ""
    /// The projects this prompt is listed in (Q-69); empty = every window.
    @State private var projects: [String] = []
    @State private var newProject: String = ""
    @State private var saveError: String?
    @State private var pendingMessageId: UUID?
    @State private var saveTimeout: Task<Void, Never>?

    private var isSaving: Bool { pendingMessageId != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("filename-style id (e.g. ship-it)", text: $idText)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .disabled(initial != nil)
                        .foregroundStyle(initial != nil ? .secondary : .primary)
                    TextField("Display label (optional)", text: $labelText)
                        .autocorrectionDisabled(true)
                    if initial == nil, !idText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        idPreviewRow
                    }
                } header: {
                    Text("Identity")
                } footer: {
                    Text(initial == nil
                         ? "Id becomes the filename on Mac (sans .txt). Allowed: letters, digits, dash, underscore. Spaces become dashes."
                         : "Id can't be changed after creation — that would orphan keystroke bindings on the Mac. Delete and recreate if you need a new id.")
                }

                Section {
                    // A UITextView wrapper: SwiftUI's TextEditor cannot turn
                    // off smart quotes and dashes, which turned `echo 'x'`
                    // into `echo ‘x’` on save.
                    PlainTextEditor(text: $bodyText)
                        .frame(minHeight: 220)
                } header: {
                    HStack {
                        Text("Prompt body")
                        Spacer()
                        Text("\(bodyText.utf8.count) B")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    // Names match PromptVariables.supported (Shared/PromptVariables.swift);
                    // {{cwd}} is iTerm2-only because Terminal.app gives no working directory.
                    Text("Tap a prompt to paste it into the selected window. The Mac fills {{folder}}, {{window}}, {{agent}}, {{date}} and {{clipboard}} ({{cwd}} in iTerm2 only). Any other {{name}} is sent as written.")
                }

                projectsSection

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(initial == nil ? "New Prompt" : "Edit Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        saveTimeout?.cancel()
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // Send the id the Mac would derive anyway, so the phone's
                        // local view of the library matches the file on disk.
                        let id = initial?.id ?? sanitizedID
                        let label = labelText.trimmingCharacters(in: .whitespaces)
                        guard !id.isEmpty, !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        let messageId = UUID()
                        let entry = PromptEntry(
                            id: id,
                            label: label.isEmpty ? id : label,
                            body: bodyText,
                            tags: PromptProjects.tags(metadataSource?.tags, settingProjects: projects + [newProject]),
                            targetAgent: metadataSource?.targetAgent,
                            description: metadataSource?.description
                        )
                        guard onSave(entry, messageId) else {
                            saveError = "Connect to the Mac before saving prompts."
                            return
                        }
                        pendingMessageId = messageId
                        saveError = nil
                        saveTimeout?.cancel()
                        saveTimeout = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 8_000_000_000)
                            guard pendingMessageId == messageId else { return }
                            pendingMessageId = nil
                            saveError = "Timed out waiting for the Mac to confirm save."
                        }
                    }
                    .disabled((initial == nil && sanitizedID.isEmpty)
                              || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || isSaving)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSaving {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Saving to Mac...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
            }
            .onAppear {
                if let source = initial ?? draft {
                    idText = source.id
                    labelText = source.label == source.id ? "" : source.label
                    bodyText = source.body
                    projects = PromptProjects.projects(inTags: source.tags)
                }
            }
            .onChange(of: latestAck?.messageId) { _, _ in
                handleAckIfNeeded()
            }
            .onDisappear {
                saveTimeout?.cancel()
            }
        }
    }

    private var metadataSource: PromptEntry? {
        initial ?? draft
    }

    /// Q-69: which projects list this prompt. Empty means every window.
    @ViewBuilder
    private var projectsSection: some View {
        Section {
            ForEach(projects, id: \.self) { name in
                Label(name, systemImage: "folder")
            }
            .onDelete { projects.remove(atOffsets: $0) }
            if let current = currentProject.flatMap(PromptProjects.cleaned), !hasProject(current) {
                Button {
                    projects.append(current)
                } label: {
                    Label("Only show in \(current)", systemImage: "plus.circle")
                }
            }
            HStack {
                TextField("Another project's folder name", text: $newProject)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .onSubmit(addTypedProject)
                Button("Add", action: addTypedProject)
                    .buttonStyle(.borderless)
                    .disabled(PromptProjects.cleaned(newProject) == nil)
            }
        } header: {
            Text("Projects")
        } footer: {
            Text(projectsFooter)
        }
    }

    private var projectsFooter: String {
        var text = projects.isEmpty
            ? "Shows in every window. Add a project and the prompt selector lists it only in windows of that folder."
            : "Listed only in windows whose folder is \(projects.joined(separator: " or ")); elsewhere it is under Other Projects. Swipe a project to remove it."
        if metadataSource?.isInherited == true {
            text += " This prompt comes from VibeCut, and the next sync replaces it, projects included."
        }
        return text
    }

    private func hasProject(_ name: String) -> Bool {
        projects.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func addTypedProject() {
        guard let name = PromptProjects.cleaned(newProject) else { return }
        if !hasProject(name) { projects.append(name) }
        newProject = ""
    }

    /// What the Mac will actually name the file. Same function the Mac runs
    /// (`Shared/PromptID.swift`), so this preview cannot drift from the write.
    private var sanitizedID: String {
        PromptID.sanitize(idText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A new prompt whose sanitized id already exists would overwrite that
    /// prompt's file. Warn rather than block: replacing is a legitimate edit,
    /// but it must not be a surprise. Locked ids (edit flow) always "collide"
    /// with themselves, so the check is new-prompt only.
    private var collidesWithExisting: Bool {
        initial == nil && !sanitizedID.isEmpty && existingIDs.contains(sanitizedID)
    }

    /// Save is impossible when nothing survives sanitization ("!!!", "///").
    private var idIsUnsavable: Bool {
        !idText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sanitizedID.isEmpty
    }

    @ViewBuilder
    private var idPreviewRow: some View {
        if idIsUnsavable {
            Label("No usable characters in that id — it can't become a filename.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
        } else if collidesWithExisting {
            Label("Will save as \(sanitizedID).txt — replaces the existing “\(sanitizedID)” prompt.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        } else {
            Text("Will save as \(sanitizedID).txt")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func handleAckIfNeeded() {
        guard let ack = latestAck, ack.messageId == pendingMessageId else { return }
        saveTimeout?.cancel()
        pendingMessageId = nil
        if ack.success {
            dismiss()
        } else {
            saveError = ack.error ?? "The Mac could not save this prompt."
        }
    }
}
