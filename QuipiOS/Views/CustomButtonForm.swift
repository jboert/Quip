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
    /// When set, the form shows a Color row and calls this on Save with the
    /// new color (nil = default) if it changed, before `onSave`. The keyboard
    /// row's hold menu uses it so Edit… covers color too.
    var onColor: ((String?) -> Void)? = nil
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
    @State private var chosenTint: String?
    @AppStorage(KeyPillSpec.autoStyleKey) private var autoKeyStyle: Bool = true
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

                if onColor != nil {
                    colorSection
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
                    TextField(autoKeyStyle ? "SF Symbol (suggested: \(suggestedStyle.symbol))"
                                           : "SF Symbol e.g. bolt.fill (optional)", text: $systemImage)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                    if let unknownSymbol {
                        // Saving is still allowed: a later iOS may know the name.
                        Text("No SF Symbol named “\(unknownSymbol)”")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Label")
                } footer: {
                    Text(autoKeyStyle
                         ? "Leave the label blank to auto-fill it from the action below. The icon and color come from the label's words; an SF Symbol, when set, replaces the icon and label on the pill."
                         : "Leave the label blank to auto-fill it from the action below. An SF Symbol, when set, replaces the label text on the pill; otherwise the label shows.")
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
            .onAppear {
                chosenTint = tint.flatMap(WindowColor.normalized)
                hydrate()
            }
            .onChange(of: text) { _, _ in autofillLabelIfNeeded() }
            .onChange(of: keystroke) { _, _ in autofillLabelIfNeeded() }
            .onChange(of: payloadKind) { _, _ in autofillLabelIfNeeded() }
        }
    }

    /// Live pill preview — the row's own `KeyPill` for the button as it
    /// stands, so the user sees the actual keyboard-row pill while editing.
    /// Shows the effective label (explicit, else auto-derived).
    private var previewPill: some View {
        KeyPill(spec: .custom(draftButton, auto: autoKeyStyle, userColor: shownTint, symbolExists: KeySymbol.exists),
                minHeight: 28)
    }

    /// The button the form would save now, for the preview.
    private var draftButton: CustomButton {
        let shown = effectiveLabel.isEmpty ? "—" : effectiveLabel
        let symbol = systemImage.trimmingCharacters(in: .whitespaces)
        return CustomButton(id: initial?.id ?? UUID(), label: shown, systemImage: symbol.isEmpty ? nil : symbol,
                            payload: currentPayload)
    }

    /// The icon and color the label and action give the button (Q-50).
    private var suggestedStyle: KeyStyle {
        KeyStyles.custom(label: effectiveLabel, payload: currentPayload)
    }

    /// The typed symbol name when iOS does not know it.
    private var unknownSymbol: String? {
        let symbol = systemImage.trimmingCharacters(in: .whitespaces)
        return symbol.isEmpty || KeySymbol.exists(symbol) ? nil : symbol
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

    private var currentPayload: CustomPayload {
        switch payloadKind {
        case .slash: return .slash(text: text, autoSubmit: autoSubmit)
        case .rawText: return .rawText(text: text, autoSubmit: autoSubmit)
        case .keystroke: return .keystroke(action: keystroke)
        }
    }

    private func save() {
        let payload = currentPayload
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let symbol = systemImage.trimmingCharacters(in: .whitespaces)
        let btn = CustomButton(
            id: initial?.id ?? UUID(),
            label: trimmed,
            systemImage: symbol.isEmpty ? nil : symbol,
            payload: payload
        )
        if let onColor, chosenTint != tint.flatMap(WindowColor.normalized) {
            onColor(chosenTint)
        }
        onSave(btn)
        dismiss()
    }

    /// The preview's color: the one being picked when the form edits color.
    private var shownTint: String? {
        onColor == nil ? tint : chosenTint
    }

    /// The no-color swatch shows the color the button gets without one.
    private var defaultSwatchFill: Color {
        autoKeyStyle ? KeyTint.defaultFill(suggestedStyle.hue, scheme: colorScheme) : colors.chipFill
    }

    private var defaultSwatchText: Color { autoKeyStyle ? .white : colors.chipText }

    /// One row of swatches, Default first, as in the window color sheet.
    private var colorSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    swatch(nil)
                    ForEach(WindowColor.palette, id: \.self) { swatch($0) }
                    if let chosenTint, !WindowColor.palette.contains(chosenTint) {
                        swatch(chosenTint)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Color")
        }
    }

    private func swatch(_ hex: String?) -> some View {
        let selected = chosenTint == hex
        return Button {
            chosenTint = hex
        } label: {
            Circle()
                .fill(hex.map { Color(hex: $0) } ?? defaultSwatchFill)
                .frame(width: 30, height: 30)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(KeyTint.text(hex, default: defaultSwatchText))
                    } else if hex == nil {
                        Image(systemName: "slash.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(defaultSwatchText)
                    }
                }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(hex.map { "Color \($0)" }
                            ?? (autoKeyStyle ? "Automatic color, \(suggestedStyle.hue.name)" : "Default color"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
