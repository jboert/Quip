import SwiftUI
import AVFoundation

/// Add/edit form for a custom button. Two-section layout: identity (label
/// + optional SF Symbol) on top, behavior (payload type + auto-submit)
/// below. Saves go through `onSave`; the parent owns the @AppStorage write.
struct CustomButtonForm: View {
    /// nil = create-new flow; non-nil = edit existing.
    let initial: CustomButton?
    /// The slot's color, so the preview matches the row. Nil = default chip.
    var tint: String? = nil
    let onSave: (CustomButton) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var label: String = ""
    @State private var systemImage: String = ""
    @State private var payloadKind: PayloadKind = .slash
    @State private var text: String = ""
    @State private var autoSubmit: Bool = true
    @State private var keystroke: String = "press_y"
    /// True once the user has typed a label themselves. Gates the auto-fill so
    /// an explicit label is never overwritten as the payload changes. Cleared
    /// when the field is emptied, so auto-fill resumes.
    @State private var labelEdited: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    private var colors: QuipColors { QuipColors(scheme: colorScheme) }

    enum PayloadKind: String, CaseIterable, Identifiable {
        case slash = "Slash"
        case rawText = "Text"
        case keystroke = "Keystroke"
        var id: String { rawValue }
    }

    private static let keystrokeOptions: [(label: String, action: String)] = [
        ("Y", "press_y"), ("N", "press_n"),
        ("1", "press_1"), ("2", "press_2"), ("3", "press_3"),
        ("Escape", "press_escape"),
        ("Return", "press_return"),
        ("Tab", "press_tab"),
        ("Shift+Tab", "press_shift_tab"),
        ("Backspace", "press_backspace"),
        ("Ctrl+C", "press_ctrl_c"),
        ("Ctrl+D", "press_ctrl_d"),
        ("Clear input", "clear_input"),
        // Listed so an edited copy of the built-in keeps its key (Q-67).
        ("Accept autocomplete", "press_right"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer(minLength: 0)
                        previewPill
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Preview")
                } footer: {
                    Text("Live preview of the pill exactly as it appears on the keyboard row.")
                }

                Section {
                    // Custom Binding so a manual edit flips `labelEdited`,
                    // locking auto-fill; clearing the field re-enables it.
                    // Auto-fill writes `label` directly (bypassing this
                    // setter) so it doesn't read as a user edit.
                    TextField("Shown on the button", text: Binding(
                        get: { label },
                        set: { newValue in
                            label = newValue
                            labelEdited = !newValue.trimmingCharacters(in: .whitespaces).isEmpty
                        }
                    ))
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                    TextField("SF Symbol e.g. bolt.fill (optional)", text: $systemImage)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Label")
                } footer: {
                    Text("Leave the label blank to auto-fill it from the action below. An SF Symbol, when set, replaces the label text on the pill; otherwise the label shows.")
                }

                Section {
                    Picker("Type", selection: $payloadKind) {
                        ForEach(PayloadKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch payloadKind {
                    case .slash:
                        TextField("/foo or /foo arg", text: $text)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                        Toggle(isOn: $autoSubmit) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Submit when tapped")
                                Text(autoSubmit
                                     ? "Sends the text, then presses Return"
                                     : "Inserts the text — you tap Send yourself")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    case .rawText:
                        TextField("Text to send", text: $text)
                        Toggle(isOn: $autoSubmit) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Submit when tapped")
                                Text(autoSubmit
                                     ? "Sends the text, then presses Return"
                                     : "Inserts the text — you tap Send yourself")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    case .keystroke:
                        Picker("Key", selection: $keystroke) {
                            ForEach(Self.keystrokeOptions, id: \.action) { opt in
                                Text(opt.label).tag(opt.action)
                            }
                        }
                    }
                } header: {
                    Text("Action")
                } footer: {
                    actionFooter
                }
            }
            .navigationTitle(initial == nil ? "New Button" : "Edit Button")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
            .onAppear { hydrate() }
            .onChange(of: text) { _, _ in autofillLabelIfNeeded() }
            .onChange(of: keystroke) { _, _ in autofillLabelIfNeeded() }
            .onChange(of: payloadKind) { _, _ in autofillLabelIfNeeded() }
        }
    }

    /// Live pill preview — mirrors the `customQuickButton` row chrome (9pt
    /// monospaced label or 16×16 symbol on the tinted chip) so the user sees
    /// the actual keyboard-row pill while editing. Shows the effective label
    /// (explicit, else auto-derived) when no symbol is set.
    private var previewPill: some View {
        let symbol = systemImage.trimmingCharacters(in: .whitespaces)
        return Group {
            if !symbol.isEmpty {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 16, height: 16)
            } else {
                Text(effectiveLabel.isEmpty ? "—" : effectiveLabel)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(KeyTint.text(tint, default: colors.chipText))
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .frame(minWidth: 20, minHeight: 28)
        .background(KeyTint.fill(tint, default: colors.chipFill))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    /// Per-type explanatory footer for the Action section.
    @ViewBuilder
    private var actionFooter: some View {
        switch payloadKind {
        case .slash:
            Text("Sends “/command” to the active window. Auto-submit presses Return — leave it off for commands that take an argument (e.g. /plan). Tip: slash keys that share a first letter auto-group into a “/x…” menu on the keyboard row.")
        case .rawText:
            Text("Sends literal text (no leading slash) to the active window. Auto-submit presses Return after.")
        case .keystroke:
            Text("Sends a single key to the Mac — no text. Handy for Y/N prompts, Esc, or Ctrl-C.")
        }
    }

    /// Label shown on the preview pill: the user's explicit label if any,
    /// otherwise the value auto-derived from the payload.
    private var effectiveLabel: String {
        let explicit = label.trimmingCharacters(in: .whitespaces)
        return explicit.isEmpty ? derivedLabel() : explicit
    }

    /// A short label derived from the current payload (slash → command word,
    /// text → first ~8 chars, keystroke → option label). Used for both the
    /// live auto-fill and the preview fallback.
    private func derivedLabel() -> String {
        switch payloadKind {
        case .slash:
            let t = text.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("/") else { return String(t.prefix(8)) }
            let body = t.dropFirst()
            let word = body.split(separator: " ").first.map(String.init) ?? String(body)
            return word
        case .rawText:
            return String(text.trimmingCharacters(in: .whitespaces).prefix(8))
        case .keystroke:
            return Self.keystrokeOptions.first { $0.action == keystroke }?.label ?? ""
        }
    }

    /// Push the derived label into the field, but only while the user hasn't
    /// typed one themselves (`labelEdited`).
    private func autofillLabelIfNeeded() {
        guard !labelEdited else { return }
        label = derivedLabel()
    }

    private var isValid: Bool {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        guard !trimmedLabel.isEmpty else { return false }
        switch payloadKind {
        case .slash:
            return text.hasPrefix("/") && text.count >= 2
        case .rawText:
            return !text.isEmpty
        case .keystroke:
            return !keystroke.isEmpty
        }
    }

    private func hydrate() {
        guard let initial else { return }
        label = initial.label
        // An existing button's label is explicit — never auto-overwrite it.
        labelEdited = !initial.label.trimmingCharacters(in: .whitespaces).isEmpty
        systemImage = initial.systemImage ?? ""
        switch initial.payload {
        case .slash(let t, let a):
            payloadKind = .slash; text = t; autoSubmit = a
        case .rawText(let t, let a):
            payloadKind = .rawText; text = t; autoSubmit = a
        case .keystroke(let action):
            payloadKind = .keystroke; keystroke = action
        }
    }

    private func save() {
        let payload: CustomPayload
        switch payloadKind {
        case .slash: payload = .slash(text: text, autoSubmit: autoSubmit)
        case .rawText: payload = .rawText(text: text, autoSubmit: autoSubmit)
        case .keystroke: payload = .keystroke(action: keystroke)
        }
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let symbol = systemImage.trimmingCharacters(in: .whitespaces)
        let btn = CustomButton(
            id: initial?.id ?? UUID(),
            label: trimmed,
            systemImage: symbol.isEmpty ? nil : symbol,
            payload: payload
        )
        onSave(btn)
        dismiss()
    }
}
